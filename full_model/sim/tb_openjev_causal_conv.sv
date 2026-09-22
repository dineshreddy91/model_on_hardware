`timescale 1ns/1ps
module tb_openjev_causal_conv;
  reg clk=0,rst_n=0,command_valid=0;
  always #5 clk=~clk;
  wire command_ready,memory_valid,memory_write,memory_response_ready,done,fault;
  reg [31:0] token_count=0,channel_count=0,kernel_size=0;
  reg [31:0] source=0,weights=1,scales=2,destination=3;
  wire [31:0] memory_tensor,memory_index,memory_data;
  reg memory_ready=0,memory_response_valid=0,memory_response_error=0;
  reg [31:0] memory_response_data=0;
  reg [31:0] memory[0:3][0:32767];
  reg pending=0,wr;
  reg [31:0] tid,index,data,fixture_word;
  integer cycle=0,delay_count=0,fd,outfd,n,case_id,i,deadline,writes;
  string path,results;
  openjev_causal_conv dut(.*);
  always @(posedge clk) begin
    if(!rst_n) begin cycle<=0;pending<=0;memory_response_valid<=0;memory_ready<=0;end
    else begin
      cycle<=cycle+1;
      memory_ready<=!pending&&!memory_response_valid&&cycle%3!=0;
      if(memory_valid&&memory_ready) begin
        if(memory_tensor>3||memory_index>=32768) $fatal(1,"bounds");
        tid<=memory_tensor;index<=memory_index;data<=memory_data;wr<=memory_write;
        pending<=1;delay_count<=3;
      end
      if(pending) begin
        if(delay_count>0) delay_count<=delay_count-1;
        else begin
          memory_response_data<=memory[tid][index];
          if(wr) begin
            if(tid!=3||index!=writes) $fatal(1,"write order");
            memory[tid][index]<=data;writes<=writes+1;
            $fwrite(outfd,"%0d %0d %h\n",case_id,index,data);
          end
          memory_response_valid<=1;pending<=0;
        end
      end
      if(memory_response_valid&&memory_response_ready) memory_response_valid<=0;
    end
  end
  initial begin
    if(!$value$plusargs("vectors=%s",path)||!$value$plusargs("results=%s",results)) $fatal(1,"paths");
    fd=$fopen(path,"r");outfd=$fopen(results,"w");if(!fd||!outfd) $fatal(1,"files");
    repeat(3) @(negedge clk);rst_n=1;@(negedge clk);
    while(!$feof(fd)) begin
      n=$fscanf(fd,"%d %d %d %d\n",case_id,token_count,channel_count,kernel_size);if(n!=4) $fatal(1,"header");
      for(i=0;i<token_count*channel_count;i=i+1) begin n=$fscanf(fd,"%h\n",fixture_word);memory[0][i]=fixture_word;end
      for(i=0;i<channel_count*kernel_size;i=i+1) begin n=$fscanf(fd,"%h\n",fixture_word);memory[1][i]=fixture_word;end
      for(i=0;i<channel_count;i=i+1) begin n=$fscanf(fd,"%h\n",fixture_word);memory[2][i]=fixture_word;end
      writes=0;command_valid=1;@(negedge clk);command_valid=0;deadline=0;
      while(!done) begin @(negedge clk);deadline=deadline+1;if(fault||deadline>5000000) $fatal(1,"convolution failed");end
      if(writes!=token_count*channel_count||pending||memory_response_valid) $fatal(1,"early completion");
    end
    kernel_size=5;command_valid=1;@(negedge clk);command_valid=0;
    if(!fault||memory_valid) $fatal(1,"invalid kernel size");
    repeat(3) @(negedge clk);
    if(!fault||command_ready) $fatal(1,"fault must remain sticky");
    rst_n=0;repeat(3) @(negedge clk);rst_n=1;@(negedge clk);
    token_count=1;channel_count=1;kernel_size=1;writes=0;
    memory[0][0]=32'h7fc00000;memory[1][0]=1;memory[2][0]=16'h3c00;
    command_valid=1;@(negedge clk);command_valid=0;deadline=0;
    while(!fault) begin @(negedge clk);deadline=deadline+1;if(done||deadline>1000) $fatal(1,"NaN not rejected");end
    if(writes!=0) $fatal(1,"NaN output committed");
    rst_n=0;repeat(3) @(negedge clk);rst_n=1;@(negedge clk);
    memory[0][0]=32'h3f800000;memory_response_error=1;
    command_valid=1;@(negedge clk);command_valid=0;deadline=0;
    while(!fault) begin @(negedge clk);deadline=deadline+1;if(done||deadline>1000) $fatal(1,"bus error not rejected");end
    if(writes!=0) $fatal(1,"bus error output committed");
    $fclose(outfd);$display("PASS causal convolution memory protocol, committed writes and invalid dimensions, NaN, sticky faults and bus errors");$finish;
  end
endmodule
