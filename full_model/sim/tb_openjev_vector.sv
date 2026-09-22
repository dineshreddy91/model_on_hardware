`timescale 1ns/1ps
module tb_openjev_vector;
  logic clk=0,rst_n=0,cv=0,cr,ce,iv=0,ir,il=0,ov,ready=0,ol,done,fault;
  logic [3:0] op;
  logic [31:0] len,eps,a,b,c,data;
  integer fd,outfd,scanned,case_id,index,cycles,count;
  logic [31:0] held;
  string path,outpath;
  always #5 clk=~clk;
  openjev_vector #(.MAX_LENGTH(64)) dut(clk,rst_n,cv,cr,ce,op,len,eps,iv,ir,a,b,c,il,ov,ready,data,ol,done,fault);
  task automatic reset;
    begin rst_n=0; cv=0; iv=0; ready=0; repeat(3) @(negedge clk); rst_n=1; @(negedge clk); end
  endtask
  initial begin
    if(!$value$plusargs("vectors=%s",path) || !$value$plusargs("results=%s",outpath)) $fatal(1,"paths");
    fd=$fopen(path,"r"); outfd=$fopen(outpath,"w");
    if(!fd || !outfd) $fatal(1,"files");
    reset(); count=0;
    while(!$feof(fd)) begin
      scanned=$fscanf(fd,"%d %h %d %h\n",case_id,op,len,eps);
      if(scanned!=4 || !cr) $fatal(1,"command");
      cv=1; @(negedge clk); cv=0;
      if(ce) $fatal(1,"rejected fixture");
      for(index=0;index<len;index=index+1) begin
        scanned=$fscanf(fd,"%h %h %h\n",a,b,c);
        if(scanned!=3 || !ir) $fatal(1,"input");
        // Bubbles in the producer must not shift tensor indices.
        repeat(index%3) @(negedge clk);
        iv=1; il=index==len-1; @(negedge clk); iv=0;
      end
      for(index=0;index<len;index=index+1) begin
        cycles=0;
        while(!ov) begin
          @(negedge clk); cycles=cycles+1;
          if(fault || cycles>100000) $fatal(1,"vector failed case=%0d",case_id);
        end
        held=data;
        repeat(2) begin
          @(negedge clk);
          if(!ov || data!==held || ol!=(index==len-1) || done) $fatal(1,"output stall");
        end
        $fwrite(outfd,"%0d %0d %h\n",case_id,index,data);
        ready=1; @(negedge clk); ready=0;
      end
      if(!done || !cr) $fatal(1,"completion");
      count=count+1;
    end
    // Invalid shape is recoverable; malformed stream is a sticky fault.
    len=65; op=0; cv=1; @(negedge clk); cv=0;
    if(!ce || !cr) $fatal(1,"oversize accepted");
    len=2; cv=1; @(negedge clk); cv=0; a=0; b=0; c=0; iv=1; il=1;
    @(negedge clk); iv=0;
    repeat(5) @(negedge clk);
    if(!fault || cr || ir || ov || done) $fatal(1,"framing fault not sticky");
    reset();
    // Numeric domain errors never emit successful completion.
    len=1; op=4; cv=1; @(negedge clk); cv=0; a=32'hbf800000; iv=1; il=1;
    @(negedge clk); iv=0;
    repeat(40) @(negedge clk);
    if(!fault || done || ov) $fatal(1,"numeric fault");
    reset();
    $display("PASS vector protocol: %0d vectors, stalls, framing/domain faults, reset",count);
    $fclose(outfd); $finish;
  end
endmodule
