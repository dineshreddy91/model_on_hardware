`timescale 1ns/1ps
module tb_openjev_attention #(parameter integer LANES=4,READ_LATENCY=0);
  logic clk=0,rst_n=0,cv=0,cr,ce,causal=0,masked=0,rv,rr,pv=0,pr,pe=0,ov,ready,ol,done,fault;
  logic [1:0] tensor_id;
  logic [31:0] nq=0,nk=0,dim=0,offset=0,index,data=0,oi,od;
  logic [3:0] code;
  logic [31:0] q[0:1023],k[0:4095],v[0:4095],mask[0:15];
  logic held=0;
  logic [31:0] held_data,held_index;
  integer fd,outfd,n,case_id,i,cycle=0,received=0,deadline,case_count=0,reads=0,start_reads,read_delay=0;
  string path,outpath;
  always #5 clk=~clk;
  assign rr=(cycle%3)!=0 && !pv && read_delay==0;
  assign ready=(cycle%5)!=0;
  generate if(LANES==0) begin
  openjev_attention_lane #(.MAX_KEYS(16),.MAX_DIM(256),.WATCHDOG_CYCLES(10000000)) dut(
    clk,rst_n,cv,cr,ce,nq,nk,dim,offset,causal,masked,rv,rr,tensor_id,index,pv,pr,data,pe,
    ov,ready,oi,od,ol,done,fault,code);
  end else begin
  openjev_attention #(.PARALLEL_QUERIES(LANES),.MAX_KEYS(16),.MAX_DIM(256),.WATCHDOG_CYCLES(10000000)) dut(
    clk,rst_n,cv,cr,ce,nq,nk,dim,offset,causal,masked,rv,rr,tensor_id,index,pv,pr,data,pe,
    ov,ready,oi,od,ol,done,fault,code);
  end endgenerate
  always @(posedge clk) begin
    if(!rst_n) begin cycle<=0; pv<=0; held<=0; read_delay<=0; end
    else begin
      cycle<=cycle+1;
      if(rv && rr) begin
        reads<=reads+1;
        if(index>=4096 || (tensor_id==0 && index>=nq*dim) ||
          ((tensor_id==1 || tensor_id==2) && index>=nk*dim) || (tensor_id==3 && index>=nk))
          $fatal(1,"read bounds");
        case(tensor_id)
          0: data<=q[index]; 1: data<=k[index]; 2: data<=v[index]; 3: data<=mask[index];
        endcase
        if(READ_LATENCY==0) pv<=1;else read_delay<=READ_LATENCY;
      end else if(read_delay>0) begin
        read_delay<=read_delay-1;if(read_delay==1) pv<=1;
      end else if(pv && pr) pv<=0;
      if(held && (!ov || od!==held_data || oi!==held_index)) $fatal(1,"output stall instability");
      held<=ov && !ready; held_data<=od; held_index<=oi;
      if(ov && ready) begin
        if(oi!=received || ol!=(received==nq*dim-1)) $fatal(1,"output index/last");
        $fwrite(outfd,"%0d 0 %0d %h\n",case_id,oi,od); received<=received+1;
      end
    end
  end
  task automatic reset;
    begin rst_n=0; cv=0; pe=0; repeat(3) @(negedge clk); rst_n=1; @(negedge clk); received=0; end
  endtask
  task automatic submit;
    begin if(!cr) $fatal(1,"not ready"); cv=1; @(negedge clk); cv=0; end
  endtask
  task automatic expect_fault(input logic [3:0] expected);
    begin
      deadline=0;
      while(!fault) begin @(negedge clk); deadline=deadline+1; if(done || deadline>20000) $fatal(1,"missing fault"); end
      repeat(5) @(negedge clk);
      if(code!=expected || cr || rv || ov || done) $fatal(1,"fault containment");
    end
  endtask
  initial begin
    if(!$value$plusargs("vectors=%s",path) || !$value$plusargs("results=%s",outpath)) $fatal(1,"paths");
    fd=$fopen(path,"r"); outfd=$fopen(outpath,"w"); if(!fd || !outfd) $fatal(1,"files"); reset();
    while(!$feof(fd)) begin
      n=$fscanf(fd,"%d %d %d %d %d %d %d\n",case_id,nq,nk,dim,offset,causal,masked);
      if(n!=7) $fatal(1,"fixture header");
      for(i=0;i<nq*dim;i=i+1) n=$fscanf(fd,"%h\n",q[i]);
      for(i=0;i<nk*dim;i=i+1) n=$fscanf(fd,"%h\n",k[i]);
      for(i=0;i<nk*dim;i=i+1) n=$fscanf(fd,"%h\n",v[i]);
      for(i=0;i<nk;i=i+1) n=$fscanf(fd,"%h\n",mask[i]);
      received=0; start_reads=reads; submit(); deadline=0;
      while(!done) begin @(negedge clk); deadline=deadline+1; if(fault || ce || deadline>5000000) $fatal(1,"attention failed case=%d code=%d",case_id,code); end
      if(received!=nq*dim || !cr) $fatal(1,"lost output");
      $display("PERF case=%0d lanes=%0d queries=%0d keys=%0d dim=%0d cycles=%0d reads=%0d",case_id,LANES,nq,nk,dim,deadline,reads-start_reads);
      case_count=case_count+1;
    end
    nq=1; nk=0; dim=1; submit(); if(!ce || !cr) $fatal(1,"zero keys accepted");
    nk=1; dim=257; submit(); if(!ce) $fatal(1,"oversize dimension accepted");
    dim=1; causal=1; offset=32'hffffffff; submit(); if(!ce) $fatal(1,"offset overflow accepted");
    reset(); nq=1; nk=1; dim=1; causal=0; offset=0; masked=1; q[0]=0; mask[0]=0; submit(); expect_fault(4);
    reset(); mask[0]=2; submit(); expect_fault(3);
    reset(); masked=0; pe=1; submit(); expect_fault(1);
    reset(); q[0]=32'h7f800000; submit(); expect_fault(2);
    reset(); q[0]=0; submit(); repeat(5) @(negedge clk); reset(); repeat(100) @(negedge clk);
    if(done || fault || ov || rv || !cr) $fatal(1,"reset in flight");
    $display("PASS attention protocol: %0d commands, masks, causal offsets, stalls, bus/numeric/domain faults, reset",case_count);
    $fclose(outfd); $finish;
  end
endmodule
