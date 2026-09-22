`timescale 1ns/1ps
module tb_openjev_scalar;
  logic clk=0,rst_n=0,iv=0,ir,ov,ready=0,error;
  logic [3:0] op;
  logic [31:0] a,b,data,held;
  logic held_error;
  integer fd,outfd,n,count,cycles;
  string path,outpath;
  always #5 clk=~clk;
  openjev_scalar dut(clk,rst_n,iv,ir,op,a,b,ov,ready,data,error);
  initial begin
    if(!$value$plusargs("vectors=%s",path) || !$value$plusargs("results=%s",outpath)) $fatal(1,"paths required");
    fd=$fopen(path,"r"); outfd=$fopen(outpath,"w");
    if(!fd || !outfd) $fatal(1,"file open");
    repeat(3) @(negedge clk); rst_n=1; @(negedge clk);
    count=0;
    while(!$feof(fd)) begin
      n=$fscanf(fd,"%h %h %h\n",op,a,b);
      if(n!=3) $fatal(1,"malformed vector");
      if(!ir) $fatal(1,"not ready");
      iv=1; @(negedge clk); iv=0; cycles=0;
      while(!ov) begin
        @(negedge clk); cycles=cycles+1;
        if(cycles>2000) $fatal(1,"scalar watchdog");
      end
      held=data; held_error=error;
      repeat(3) begin
        @(negedge clk);
        if(!ov || data!==held || error!==held_error || ir) $fatal(1,"output backpressure");
      end
      $fwrite(outfd,"%h %h %h %h %d\n",op,a,b,data,error);
      ready=1; @(negedge clk); ready=0; count=count+1;
    end
    // Reset while executing must discard the interrupted result.
    op=2; a=32'h3f800000; iv=1; @(negedge clk); iv=0;
    repeat(4) @(negedge clk);
    rst_n=0; @(negedge clk);
    if(ov || ir) $fatal(1,"reset did not quiesce interface");
    rst_n=1; repeat(410) @(negedge clk);
    if(ov || !ir) $fatal(1,"stale result after reset");
    $display("PASS scalar protocol: %0d commands, backpressure, reset",count);
    $fclose(outfd); $finish;
  end
endmodule
