`timescale 1ns/1ps
module tb_openjev_rope;
  reg clk=0,rst_n=0,command_valid=0;
  always #5 clk=~clk;
  wire command_ready,memory_valid,memory_write,memory_response_ready,done,fault;
  reg [31:0] token_count=0,head_count=0,head_dim=0,rotary_dim=0;
  reg [31:0] source=0,cosine=1,sine=2,destination=3;
  wire [31:0] memory_tensor,memory_index,memory_data;
  reg memory_ready=0,memory_response_valid=0,memory_response_error=0;
  reg [31:0] memory_response_data=0;
  reg [31:0] memory[0:3][0:1023];
  reg pending=0,wr;
  reg [31:0] tid,index,data,fixture_word;
  integer cycle=0,delay_count=0,fd,outfd,n,case_id,i,deadline,writes;
  string path,results;
  openjev_rope dut(.*);
  always @(posedge clk) begin
    if(!rst_n) begin cycle<=0;pending<=0;memory_response_valid<=0;memory_ready<=0;end
    else begin
      cycle<=cycle+1;
      memory_ready<=!pending&&!memory_response_valid&&cycle%3!=0;
      if(memory_valid&&memory_ready) begin
        if(memory_tensor>3||memory_index>=1024) $fatal(1,"bounds");
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
      n=$fscanf(fd,"%d %d %d %d %d\n",case_id,token_count,head_count,head_dim,rotary_dim);if(n!=5) $fatal(1,"header");
      for(i=0;i<token_count*head_count*head_dim;i=i+1) begin n=$fscanf(fd,"%h\n",fixture_word);memory[0][i]=fixture_word;end
      for(i=0;i<token_count*rotary_dim;i=i+1) begin n=$fscanf(fd,"%h\n",fixture_word);memory[1][i]=fixture_word;end
      for(i=0;i<token_count*rotary_dim;i=i+1) begin n=$fscanf(fd,"%h\n",fixture_word);memory[2][i]=fixture_word;end
      writes=0;command_valid=1;@(negedge clk);command_valid=0;deadline=0;
      while(!done) begin @(negedge clk);deadline=deadline+1;if(fault||deadline>500000) $fatal(1,"rotary failed");end
      if(writes!=token_count*head_count*head_dim||pending||memory_response_valid) $fatal(1,"early completion");
    end
    rotary_dim=3;command_valid=1;@(negedge clk);command_valid=0;
    if(!fault||memory_valid) $fatal(1,"odd rotary dimension");
    rst_n=0;repeat(3) @(negedge clk);rst_n=1;@(negedge clk);
    rotary_dim=4;destination=source;command_valid=1;@(negedge clk);command_valid=0;
    if(!fault||memory_valid) $fatal(1,"in-place rotary not rejected");
    $fclose(outfd);$display("PASS rotary memory protocol, committed writes and invalid dimension rejection");$finish;
  end
endmodule
