module tb_openjev_small_integer;
  import openjev_fp32_pkg::*;
  integer fd,n,op,count=0;
  reg [31:0] data,expected,result;
  string path;
  initial begin
    if(!$value$plusargs("vectors=%s",path)) $fatal(1,"vectors");
    fd=$fopen(path,"r");if(!fd) $fatal(1,"file");
    while(!$feof(fd)) begin
      n=$fscanf(fd,"%d %h %h\n",op,data,expected);if(n!=3) $fatal(1,"fixture");
      result=op==0 ? fp_from_u13(data[12:0]) : fp_from_i10(data[9:0]);
      if(result!==expected) $fatal(1,"small integer conversion");
      count=count+1;
    end
    $display("PASS bounded integer conversions: %0d exhaustive values",count);$finish;
  end
endmodule
