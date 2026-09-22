`timescale 1ns/1ps
module tb_openjev_gated_delta;
  logic clk=0,rst_n=0,cv=0,cr,ce,initial_memory=0,reuse=0,rv,rr,pv=0,pr,pe=0,ov,ready,os,ol,done,fault;
  logic [2:0] tensor_id;
  logic [31:0] nt=0,kd=0,vd=0,index,data=0,oi,od;
  logic [3:0] code;
  logic [31:0] q[0:1023],k[0:1023],v[0:1023],s[0:16383],g[0:7],beta[0:7];
  logic held=0,held_kind,held_last;
  logic [31:0] held_data,held_index;
  integer fd,outfd,n,case_id,mode,i,cycle=0,received=0,state_received=0,deadline,case_count=0;
  string path,outpath;
  always #5 clk=~clk;
  assign rr=(cycle%3)!=0 && !pv;
  assign ready=(cycle%5)!=0;
  openjev_gated_delta #(.MAX_TOKENS(8),.WATCHDOG_CYCLES(25000000)) dut(
    clk,rst_n,cv,cr,ce,nt,kd,vd,initial_memory,reuse,rv,rr,tensor_id,index,pv,pr,data,pe,
    ov,ready,os,oi,od,ol,done,fault,code);
  always @(posedge clk) begin
    if(!rst_n) begin cycle<=0; pv<=0; held<=0; end
    else begin
      cycle<=cycle+1;
      if(rv && rr) begin
        if((tensor_id<=1 && index>=nt*kd) || (tensor_id==2 && index>=nt*vd) ||
          (tensor_id==3 && index>=kd*vd) || (tensor_id>=4 && index>=nt)) $fatal(1,"read bounds");
        case(tensor_id)
          0: data<=q[index]; 1: data<=k[index]; 2: data<=v[index];
          3: data<=s[index]; 4: data<=g[index]; 5: data<=beta[index];
          default: $fatal(1,"unknown tensor");
        endcase
        pv<=1;
      end else if(pv && pr) pv<=0;
      if(held && (!ov || od!==held_data || oi!==held_index || os!==held_kind || ol!==held_last))
        $fatal(1,"output stall instability");
      held<=ov && !ready; held_data<=od; held_index<=oi; held_kind<=os; held_last<=ol;
      if(ov && ready) begin
        if(os) begin
          if(oi!=state_received || received!=nt*vd || ol!=(state_received==kd*vd-1)) $fatal(1,"state ordering");
          state_received<=state_received+1;
        end else begin
          if(oi!=received || ol || state_received!=0) $fatal(1,"output ordering");
          received<=received+1;
        end
        $fwrite(outfd,"%0d %0d %0d %h\n",case_id,os,oi,od);
      end
    end
  end
  task automatic reset;
    begin rst_n=0; cv=0; pe=0; reuse=0; initial_memory=0; repeat(3) @(negedge clk); rst_n=1; @(negedge clk); received=0; state_received=0; end
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
      n=$fscanf(fd,"%d %d %d %d %d\n",case_id,nt,kd,vd,mode);
      if(n!=5) $fatal(1,"fixture header");
      initial_memory=mode==1; reuse=mode==2;
      for(i=0;i<nt*kd;i=i+1) n=$fscanf(fd,"%h\n",q[i]);
      for(i=0;i<nt*kd;i=i+1) n=$fscanf(fd,"%h\n",k[i]);
      for(i=0;i<nt*vd;i=i+1) n=$fscanf(fd,"%h\n",v[i]);
      for(i=0;i<kd*vd;i=i+1) n=$fscanf(fd,"%h\n",s[i]);
      for(i=0;i<nt;i=i+1) n=$fscanf(fd,"%h\n",g[i]);
      for(i=0;i<nt;i=i+1) n=$fscanf(fd,"%h\n",beta[i]);
      received=0; state_received=0; submit(); deadline=0;
      while(!done) begin @(negedge clk); deadline=deadline+1; if(fault || ce || deadline>20000000) $fatal(1,"delta failed case=%d code=%d",case_id,code); end
      if(received!=nt*vd || state_received!=kd*vd || !cr) $fatal(1,"lost output");
      case_count=case_count+1;
    end
    nt=0; submit(); if(!ce || !cr) $fatal(1,"zero tokens accepted");
    nt=1; kd=129; submit(); if(!ce) $fatal(1,"oversize dimension");
    kd=1; vd=1; reuse=1; initial_memory=0; submit(); if(!ce) $fatal(1,"incompatible cached state accepted");
    reset(); reuse=1; submit(); if(!ce) $fatal(1,"uninitialized cached state accepted");
    reset(); q[0]=0; k[0]=0; v[0]=0; g[0]=32'h3f800000; beta[0]=0; submit(); expect_fault(3);
    reset(); g[0]=0; beta[0]=32'h40000000; submit(); expect_fault(3);
    reset(); pe=1; submit(); expect_fault(1);
    reset(); q[0]=32'h7fc00000; submit(); expect_fault(2);
    reset(); q[0]=0; beta[0]=0; submit(); repeat(5) @(negedge clk); reset(); repeat(100) @(negedge clk);
    if(done || fault || ov || rv || !cr) $fatal(1,"reset in flight");
    $display("PASS gated-delta protocol: %0d commands, state import/reuse/export, stalls, bus/numeric/domain faults, reset",case_count);
    $fclose(outfd); $finish;
  end
endmodule
