`timescale 1ns/1ps
module tb_openjev_command_scheduler;
  logic clk=0,rst_n=0,cv=0,cr,cl=0,qv,qr=0,rv=0,rr,re=0,ov,ready=0,ol,fault;
  logic [1:0] ce=0,qe,engine=0;
  logic [3:0] op=0,qop,code;
  logic [15:0] tag=0,qt,rt=0,ot;
  logic [28:0] a=0,b=0,c=0,dst=0,qa,qb,qc,qd;
  logic [31:0] count=0,width=0,epsilon=0,qn,qw,qeps,completed;
  integer cases=0;
  always #5 clk=~clk;
  openjev_command_scheduler #(.ENABLED_ENGINES(3'b011),.WATCHDOG_CYCLES(16)) dut(
    clk,rst_n,cv,cr,ce,op,tag,cl,a,b,c,dst,count,width,epsilon,
    qv,qr,qe,qop,qt,qa,qb,qc,qd,qn,qw,qeps,
    rv,rr,engine,rt,re,ov,ready,ot,ol,completed,fault,code);
  task automatic reset;
    begin
      rst_n=0; cv=0; qr=0; rv=0; ready=0; re=0;
      repeat(3) @(negedge clk); rst_n=1; @(negedge clk);
      ce=0; op=0; tag=16'h1234; cl=0; a=0; b=4096; c=8192;
      dst=29'h2000000; count=16; width=32; epsilon=32'h3727c5ac;
    end
  endtask
  task automatic submit;
    begin if(!cr) $fatal(1,"not ready"); cv=1; @(negedge clk); cv=0; repeat(2) @(negedge clk); end
  endtask
  task automatic expect_fault(input logic [3:0] expected);
    begin
      repeat(20) @(negedge clk);
      if(!fault || code!==expected || cr || qv || rr || ov || completed!=0)
        $fatal(1,"fault expected=%0d actual=%0d",expected,code);
      repeat(4) @(negedge clk);
      if(!fault) $fatal(1,"fault not sticky");
      cases=cases+1;
    end
  endtask
  task automatic success;
    begin
      submit();
      repeat(3) begin
        if(!qv || qe!=ce || qop!=op || qt!=tag || qa!=a || qb!=b || qc!=c ||
           qd!=dst || qn!=count || qw!=width || qeps!=epsilon || ov || cr)
          $fatal(1,"dispatch stability");
        @(negedge clk);
      end
      qr=1; @(negedge clk); qr=0;
      repeat(3) begin
        if(ov || qv || !rr) $fatal(1,"early completion");
        @(negedge clk);
      end
      engine=ce; rt=tag; rv=1; @(negedge clk); rv=0;
      repeat(3) begin
        if(!ov || ot!=tag || ol!=cl || cr || fault) $fatal(1,"completion stability");
        @(negedge clk);
      end
      ready=1; @(negedge clk); ready=0;
      if(!cr || ov) $fatal(1,"completion release");
      cases=cases+1;
    end
  endtask
  initial begin
    reset(); success(); ce=1; op=0; tag=16'h1235; cl=1; count=6144; width=1024;
    b=29'h7a1000; success();
    if(completed!=2) $fatal(1,"lost completion count");
    reset(); ce=2; submit(); expect_fault(1);
    reset(); count=0; submit(); expect_fault(2);
    reset(); count=32'hffffffff; submit(); expect_fault(2);
    reset(); op=11; submit(); expect_fault(2);
    reset(); ce=1; width=33; submit(); expect_fault(2);
    reset(); op=9; epsilon=32'hbf800000; submit(); expect_fault(2);
    reset(); dst=0; submit(); expect_fault(3);
    reset(); a=1; submit(); expect_fault(3);
    reset(); ce=1; count=8192; width=4096; b=29'h1ffff000; submit(); expect_fault(3);
    reset(); a=dst; submit(); expect_fault(4);
    reset(); b=dst; submit(); expect_fault(4);
    reset(); op=9; c=dst; submit(); expect_fault(4);
    reset(); submit(); expect_fault(5); // Engine never accepts.
    reset(); submit(); qr=1; @(negedge clk); qr=0; expect_fault(5);
    reset(); submit(); qr=1; @(negedge clk); qr=0; rv=1; rt=tag+1; engine=ce;
    @(negedge clk); rv=0; expect_fault(6);
    reset(); submit(); qr=1; @(negedge clk); qr=0; rv=1; rt=tag; engine=1;
    @(negedge clk); rv=0; expect_fault(6);
    reset(); submit(); qr=1; @(negedge clk); qr=0; rv=1; rt=tag; engine=ce; re=1;
    @(negedge clk); rv=0; expect_fault(7);
    reset(); submit(); qr=1; @(negedge clk); reset();
    if(!cr || completed || fault || qv || ov) $fatal(1,"reset in flight");
    $display("PASS command scheduler: %0d success/fault scenarios, reset in flight",cases);
    $finish;
  end
endmodule
