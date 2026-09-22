`timescale 1ns/1ps
module tb_openjev_half;
  import openjev_fp32_pkg::*;
  reg [15:0] bits;
  reg [31:0] expected;
  integer fd,n,count=0;
  string vectors;
  initial begin
    if(!$value$plusargs("vectors=%s",vectors)) $fatal(1,"Missing vectors");
    fd=$fopen(vectors,"r");if(!fd) $fatal(1,"Cannot open vectors");
    while(!$feof(fd)) begin
      n=$fscanf(fd,"%h %h\n",bits,expected);if(n!=2) $fatal(1,"Malformed vector");
      if(fp_from_half(bits)!==expected) $fatal(1,"Half conversion %h expected %h got %h",bits,expected,fp_from_half(bits));
      count=count+1;
    end
    if(count!=63488) $fatal(1,"Missing finite encodings");
    $display("PASS all %0d finite binary16 conversions, signed zero and subnormals",count);$finish;
  end
endmodule
