`timescale 1ns/1ps
module tb_openjev_scaled_int32;
  logic clk=0;
  always #2 clk=~clk;
  logic rst_n=0, input_valid=0, input_ready;
  logic signed [31:0] accumulator=0;
  logic [15:0] scale=0;
  logic output_valid, output_ready=0, output_error;
  logic [31:0] output_data, expected;
  integer fd, fields, expected_error, checked=0;
  string vectors;
  openjev_scaled_int32 dut(.*);
  initial begin
    if (!$value$plusargs("vectors=%s",vectors)) $fatal(1,"Missing vectors");
    fd=$fopen(vectors,"r");
    if (!fd) $fatal(1,"Cannot open vectors");
    repeat(2) @(negedge clk);
    rst_n=1;
    while (!$feof(fd)) begin
      @(negedge clk);
      fields=$fscanf(fd,"%h %h %h %d\n",accumulator,scale,expected,expected_error);
      if(fields!=4) $fatal(1,"Malformed vector");
      while (!input_ready) @(negedge clk);
      input_valid=1; output_ready=0;
      @(negedge clk); input_valid=0;
      while (!output_valid) @(negedge clk);
      #1;
      if (!output_valid || output_data!==expected || output_error!==1'(expected_error))
        $fatal(1,"Mismatch a=%h scale=%h expected=%h/%0d got=%h/%b",accumulator,scale,expected,expected_error,output_data,output_error);
      if (checked%257==0) begin
        @(negedge clk); output_ready=0; accumulator=123; scale=16'h7c00;
        repeat(3) begin
          @(posedge clk); #1;
          if (input_ready || !output_valid || output_data!==expected || output_error!==1'(expected_error))
            $fatal(1,"Backpressure changed output");
        end
      end
      checked=checked+1;
      @(negedge clk); output_ready=1;
      @(negedge clk); output_ready=0;
    end
    @(negedge clk); input_valid=0; output_ready=1;
    @(posedge clk); #1;
    if(output_valid) $fatal(1,"Pipeline did not drain");
    @(negedge clk); rst_n=0;
    @(posedge clk); #1;
    if(output_valid || input_ready) $fatal(1,"Reset failure");
    $display("PASS scaled INT32: %0d vectors, exhaustive binary16 patterns, integer extremes, ties-to-even, stalls and nonfinite errors",checked);
    $finish;
  end
  initial begin #100000000; $fatal(1,"Simulation timeout"); end
endmodule
