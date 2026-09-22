`timescale 1ns/1ps
module tb_openjev_fp32_alu;
  reg clk=0,rst_n=0,input_valid=0,output_ready=0,multiply=0;
  always #5 clk=~clk;
  reg [31:0] input_a=0,input_b=0,expected;
  integer fd,n,count=0,op;
  wire input_ready,output_valid;
  wire scale_mode=op==2;
  wire signed [31:0] scale_power=input_b;
  wire [31:0] output_data;
  string path;
  openjev_fp32_alu dut(.*);
  initial begin
    if(!$value$plusargs("vectors=%s",path)) $fatal(1,"vectors required");
    fd=$fopen(path,"r");if(!fd) $fatal(1,"open vectors");
    repeat(3) @(negedge clk);rst_n=1;@(negedge clk);
    while(!$feof(fd)) begin
      n=$fscanf(fd,"%d %h %h %h\n",op,input_a,input_b,expected);
      if(n!=4) $fatal(1,"malformed fixture");
      if(!input_ready) $fatal(1,"not ready");
      multiply=op==1;input_valid=1;@(negedge clk);input_valid=0;
      wait(output_valid);@(negedge clk);
      if(output_data!==expected) $fatal(1,"op=%d a=%h b=%h got=%h expected=%h index=%d",op,input_a,input_b,output_data,expected,count);
      repeat(count%3) begin @(negedge clk);if(!output_valid||output_data!==expected) $fatal(1,"stall");end
      output_ready=1;@(negedge clk);output_ready=0;count=count+1;
    end
    $display("PASS registered FP32 ALU: %0d bit-exact values with output stalls",count);
    $finish;
  end
endmodule
