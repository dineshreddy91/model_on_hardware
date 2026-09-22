`timescale 1ns/1ps
module tb_openjev_hbm_pipeline;
  import openjev_fp32_pkg::*;
  logic clk=0,rst_n=0,cv=0,cr,qv,qr,rv,rr,re,ov,ready=0,ol,fault;
  logic [3:0] op=0,qop,code;
  logic [15:0] tag=0,qt,ot;
  logic [1:0] qe;
  logic [28:0] qa,qb,qc,qd;
  logic [31:0] count=0,epsilon=0,qn,qw,qeps,completed;
  logic rdv,rdr,respv=0,respr;
  logic [4:0] bank;
  logic [28:0] address;
  logic [255:0] read_data;
  logic [1:0] read_status=0;
  logic [63:0] awaddr,wstrb,held_aw;
  logic [511:0] wdata,held_w;
  logic [63:0] held_strobe;
  logic [7:0] awlen;
  logic [2:0] awsize;
  logic [1:0] awburst;
  logic awv,awr,wv,wr,wl,bv=0,br;
  logic [1:0] bresp=0;
  logic [15:0] bid=0;
  logic aw_pending=0,w_pending=0;
  integer clock_count=0,delay_count=0,fd,outfd,scanned,case_id,i,j,logical_index,base_index;
  integer writes=0,cycles,case_count=0;
  logic [31:0] inputs_a[0:4095],inputs_b[0:4095],inputs_c[0:4095],outputs[0:4103];
  logic [31:0] word;
  string path,outpath;
  always #5 clk=~clk;
  assign rdr=(clock_count%3)!=0 && !respv;
  assign awr=(clock_count%4)==1 && !aw_pending && !bv;
  assign wr=(clock_count%4)==3 && !w_pending && !bv;
  openjev_command_scheduler #(.ENABLED_ENGINES(3'b001),.WATCHDOG_CYCLES(1000000)) scheduler(
    .clk(clk),.rst_n(rst_n),.command_valid(cv),.command_ready(cr),.command_engine(2'd0),
    .command_opcode(op),.command_tag(tag),.command_last(1'b1),
    .command_a(29'd0),.command_b(29'd4096),.command_c(29'd8192),.command_dst(29'h2000000),
    .command_count(count),.command_width(32'd0),.command_epsilon(epsilon),
    .request_valid(qv),.request_ready(qr),.request_engine(qe),.request_opcode(qop),.request_tag(qt),
    .request_a(qa),.request_b(qb),.request_c(qc),.request_dst(qd),.request_count(qn),
    .request_width(qw),.request_epsilon(qeps),.response_valid(rv),.response_ready(rr),
    .response_engine(qe),.response_tag(qt),.response_error(re),.completion_valid(ov),
    .completion_ready(ready),.completion_tag(ot),.completion_last(ol),
    .completed_commands(completed),.fault(fault),.fault_code(code));
  openjev_hbm_vector engine(
    .clk(clk),.rst_n(rst_n),.command_valid(qv),.command_ready(qr),.opcode(qop),
    .source_a(qa),.source_b(qb),.source_c(qc),.destination(qd),.length(qn),.epsilon(qeps),
    .read_valid(rdv),.read_ready(rdr),.read_bank(bank),.read_address(address),
    .read_response_valid(respv),.read_response_ready(respr),.read_data(read_data),.read_status(read_status),
    .awaddr(awaddr),.awlen(awlen),.awsize(awsize),.awburst(awburst),.awvalid(awv),.awready(awr),
    .wdata(wdata),.wstrb(wstrb),.wlast(wl),.wvalid(wv),.wready(wr),
    .bvalid(bv),.bready(br),.bresp(bresp),.bid(bid),
    .completion_valid(rv),.completion_ready(rr),.completion_error(re));

  // Passive memory model only: values are supplied by the independent fixture.
  // AW and W arrive on different cycles, followed by delayed B responses.
  always @(posedge clk) begin
    if(!rst_n) begin
      clock_count<=0; respv<=0; bv<=0; aw_pending<=0; w_pending<=0; delay_count<=0; writes<=0;
    end else begin
      clock_count<=clock_count+1;
      if(rdv && rdr) begin
        base_index=(address>>12)*4096;
        if(base_index>8192) $fatal(1,"read escaped source regions");
        logical_index=(((address-base_index)>>8)*8192+bank*256+((address-base_index)&255))/4;
        if(logical_index+7>=4096) $fatal(1,"read out of bounds");
        for(integer k=0;k<8;k=k+1) begin
          case(base_index)
            0: read_data[k*32+:32]<=inputs_a[logical_index+k];
            4096: read_data[k*32+:32]<=inputs_b[logical_index+k];
            8192: read_data[k*32+:32]<=inputs_c[logical_index+k];
          endcase
        end
        respv<=1;
      end else if(respv && respr) respv<=0;
      if(awv && awr) begin
        if(awlen!=0 || awsize!=6 || awburst!=1 || awaddr[5:0]!=0) $fatal(1,"AXI address format");
        held_aw<=awaddr; aw_pending<=1;
      end
      if(wv && wr) begin
        if(!wl || (wstrb!=64'hffffffff && wstrb!=64'hffffffff00000000)) $fatal(1,"AXI data format");
        held_w<=wdata; held_strobe<=wstrb; w_pending<=1;
      end
      if(aw_pending && w_pending && !bv) begin
        if(delay_count==7) begin
          if(held_aw<64'h1000000000 || (held_aw-64'h1000000000)%64'h20000000<64'h2000000)
            $fatal(1,"write escaped scratch region");
          logical_index=(((held_aw-64'h1000000000)%64'h20000000-64'h2000000)>>8)*8192+
            ((held_aw-64'h1000000000)/64'h20000000)*256+(held_aw&255);
          logical_index=logical_index/4;
          for(integer k=0;k<16;k=k+1)
            if(held_strobe[k*4+:4]==4'hf) begin
              if(logical_index+k>=4104) $fatal(1,"write out of bounds");
              outputs[logical_index+k]<=held_w[k*32+:32];
            end
          bv<=1; delay_count<=0;
        end else delay_count<=delay_count+1;
      end
      if(bv && br) begin bv<=0; aw_pending<=0; w_pending<=0; writes<=writes+1; end
      if(ov && (aw_pending || w_pending || bv || writes!=(count+7)/8))
        $fatal(1,"completion before all writes committed");
    end
  end

  task automatic inject_bus_fault(input integer kind);
    begin
      rst_n=0; cv=0; ready=0; read_status=0; bresp=0; bid=0;
      repeat(3) @(negedge clk); rst_n=1; @(negedge clk);
      op=0; count=9; tag=16'hff00+16'(kind); epsilon=32'h3727c5ac;
      if(kind==0) read_status=2;
      else if(kind==1) bresp=2;
      else bid=1;
      cv=1; @(negedge clk); cv=0; cycles=0;
      while(!fault) begin
        @(negedge clk); cycles=cycles+1;
        if(ov || cycles>10000) $fatal(1,"bus error lost or falsely completed");
      end
      repeat(10) @(negedge clk);
      if(code!=7 || ov || cr || rdv || awv || wv) $fatal(1,"bus fault not contained");
    end
  endtask

  initial begin
    if(!$value$plusargs("vectors=%s",path) || !$value$plusargs("results=%s",outpath)) $fatal(1,"paths");
    fd=$fopen(path,"r"); outfd=$fopen(outpath,"w");
    if(!fd || !outfd) $fatal(1,"files");
    repeat(3) @(negedge clk); rst_n=1; @(negedge clk);
    while(!$feof(fd)) begin
      scanned=$fscanf(fd,"%d %h %d %h\n",case_id,op,count,epsilon);
      if(scanned!=4 || !cr) $fatal(1,"fixture command");
      for(i=0;i<4096;i=i+1) begin inputs_a[i]=0; inputs_b[i]=0; inputs_c[i]=0; end
      for(i=0;i<4104;i=i+1) outputs[i]=32'hdeadbeef;
      for(i=0;i<count;i=i+1) begin
        scanned=$fscanf(fd,"%h %h %h\n",inputs_a[i],inputs_b[i],inputs_c[i]);
        if(scanned!=3) $fatal(1,"fixture data");
      end
      tag=16'(case_id); cv=1; writes=0; @(negedge clk); cv=0; cycles=0;
      while(!ov) begin
        @(negedge clk); cycles=cycles+1;
        if(fault || cycles>500000) $fatal(1,"pipeline fault=%d case=%d",code,case_id);
      end
      if(ot!=tag || !ol || completed!=case_count+1) $fatal(1,"scheduler identity");
      for(i=0;i<count;i=i+1) $fwrite(outfd,"%0d %0d %h\n",case_id,i,outputs[i]);
      for(i=count;i<((count+7)/8)*8;i=i+1) if(outputs[i]!==0) $fatal(1,"padding not zero");
      for(i=((count+7)/8)*8;i<4104;i=i+1) if(outputs[i]!==32'hdeadbeef) $fatal(1,"adjacent data changed");
      repeat(3) @(negedge clk);
      ready=1; @(negedge clk); ready=0; case_count=case_count+1;
    end
    inject_bus_fault(0); inject_bus_fault(1); inject_bus_fault(2);
    $display("PASS scheduled HBM vector pipeline: %0d commands, AXI stalls, write completion, padding guards, read/write/ID faults",case_count);
    $fclose(outfd); $finish;
  end
endmodule
