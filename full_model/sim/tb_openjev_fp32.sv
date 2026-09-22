`timescale 1ns/1ps
module tb_openjev_fp32;
  import openjev_fp32_pkg::*;
  integer fd, scanned, count, op;
  logic [31:0] a,b,expected,result;
  string path;
  initial begin
    if (!$value$plusargs("vectors=%s",path)) $fatal(1,"Missing vectors");
    fd=$fopen(path,"r");
    if (!fd) $fatal(1,"Cannot open vectors");
    count=0;
    while (!$feof(fd)) begin
      scanned=$fscanf(fd,"%d %h %h %h\n",op,a,b,expected);
      if(scanned!=4) $fatal(1,"Malformed vector");
      result=op==0 ? fp_add(a,b) : fp_mul(a,b);
      if(result!==expected) $fatal(1,"op=%d a=%h b=%h got=%h expected=%h vector=%d",op,a,b,result,expected,count);
      count=count+1;
    end
    $display("PASS FP32 add/multiply: %0d bit-exact vectors",count);
    $finish;
  end
endmodule
