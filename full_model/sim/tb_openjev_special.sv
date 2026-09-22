`timescale 1ns/1ps
module tb_openjev_special;
  reg clk=0,rst_n=0,input_valid=0,output_ready=0,opcode=0;
  always #5 clk=~clk;
  reg [31:0] input_data=0;
  wire input_ready,output_valid,output_error;
  wire [31:0] output_data;
  integer fd,outfd,n,op,count=0,cycles;
  string path,results;
  openjev_special dut(.*);
  initial begin
    if(!$value$plusargs("vectors=%s",path)||!$value$plusargs("results=%s",results)) $fatal(1,"paths");
    fd=$fopen(path,"r");outfd=$fopen(results,"w");
    if(!fd||!outfd) $fatal(1,"files");
    repeat(3) @(negedge clk);rst_n=1;@(negedge clk);
    while(!$feof(fd)) begin
      n=$fscanf(fd,"%d %h\n",op,input_data);if(n!=2) $fatal(1,"fixture");
      opcode=op;input_valid=1;@(negedge clk);input_valid=0;cycles=0;
      while(!output_valid) begin @(negedge clk);cycles=cycles+1;if(cycles>10000) $fatal(1,"timeout");end
      $fwrite(outfd,"%d %h %h %d\n",op,input_data,output_data,output_error);
      repeat(3) @(negedge clk);
      if(!output_valid) $fatal(1,"stall");
      output_ready=1;@(negedge clk);output_ready=0;count=count+1;
    end
    $fclose(outfd);$display("PASS special activations protocol: %0d cases",count);$finish;
  end
endmodule
