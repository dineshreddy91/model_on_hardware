`timescale 1ns/1ps
module tb_openjev_quantize_row;
  reg clk=0,rst_n=0,command_valid=0,input_valid=0,input_last=0;
  always #5 clk=~clk;
  reg [31:0] length=0,input_data=0;
  wire command_ready,command_error,input_ready,output_valid,output_scale,output_last,done,fault;
  wire [31:0] output_index,output_data;
  integer cycle=0,fd,outfd,n,row,i,count=0,scales=0,deadline;
  wire output_ready=cycle%5!=0;
  string path,results;
  openjev_quantize_row dut(.*);
  always @(posedge clk) begin
    cycle<=cycle+1;
    if(rst_n&&output_valid&&output_ready) begin
      $fwrite(outfd,"%0d %0d %0d %h\n",row,output_scale,output_index,output_data);
      if(output_scale) begin
        if(count||scales||output_last) $fatal(1,"scale ordering");scales<=scales+1;
      end else begin
        if(scales!=1||output_index!=count||output_last!=(count==length-1)) $fatal(1,"value ordering");
        count<=count+1;
      end
    end
  end
  initial begin
    if(!$value$plusargs("vectors=%s",path)||!$value$plusargs("results=%s",results)) $fatal(1,"paths");
    fd=$fopen(path,"r");outfd=$fopen(results,"w");if(!fd||!outfd) $fatal(1,"files");
    repeat(3) @(negedge clk);rst_n=1;@(negedge clk);
    while(!$feof(fd)) begin
      n=$fscanf(fd,"%d %d\n",row,length);if(n!=2) $fatal(1,"header");
      count=0;scales=0;command_valid=1;@(negedge clk);command_valid=0;
      for(i=0;i<length;i=i+1) begin
        n=$fscanf(fd,"%h\n",input_data);if(n!=1||!input_ready) $fatal(1,"input");
        input_valid=1;input_last=i==length-1;@(negedge clk);input_valid=0;
        repeat(i%3) @(negedge clk);
      end
      deadline=0;
      while(!done) begin @(negedge clk);deadline=deadline+1;if(fault||deadline>1000000) $fatal(1,"quantize failure");end
      if(count!=length||scales!=1) $fatal(1,"lost output");
    end
    length=0;command_valid=1;@(negedge clk);command_valid=0;
    if(!command_error) $fatal(1,"invalid length accepted");
    length=1;command_valid=1;@(negedge clk);command_valid=0;
    input_valid=1;input_data=32'h7fc00000;input_last=1;@(negedge clk);input_valid=0;
    if(!fault) $fatal(1,"nonfinite accepted");
    $fclose(outfd);$display("PASS row quantizer protocol, output stalls, invalid shape and NaN rejection");$finish;
  end
endmodule
