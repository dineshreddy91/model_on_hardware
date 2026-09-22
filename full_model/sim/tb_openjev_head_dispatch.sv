`timescale 1ns/1ps
module tb_openjev_head_dispatch;
  reg clk=0,rst_n=0,command_valid=0,completion_ready=0;
  always #5 clk=~clk;
  wire command_ready,completion_valid,completion_error,memory_valid,memory_write,memory_response_ready;
  reg [511:0] command_data=0;
  wire [31:0] completion_tag,memory_tensor,memory_index,memory_data;
  reg memory_ready=0,memory_response_valid=0,memory_response_error=0;
  reg [31:0] memory_response_data=0;
  reg [31:0] memory[0:8191];
  reg pending=0,saved_write;
  reg [31:0] saved_address,saved_data;
  integer cycle=0,delay_count=0,fd,outfd,n,case_id,words,i,address,deadline;
  reg [31:0] datum;
  string path,results;
  openjev_head_dispatch dut(.*);
  always @(posedge clk) begin
    if(!rst_n) begin memory_ready<=0;memory_response_valid<=0;pending<=0;cycle<=0;end
    else begin
      cycle<=cycle+1;
      memory_ready<=!pending&&!memory_response_valid&&cycle%3!=0;
      if(memory_valid&&memory_ready) begin
        if(memory_tensor>=8||memory_index>=1024) $fatal(1,"memory bounds");
        saved_address<=memory_tensor*1024+memory_index;
        saved_data<=memory_data;saved_write<=memory_write;pending<=1;delay_count<=4;
      end
      if(pending) begin
        if(delay_count>0) delay_count<=delay_count-1;
        else begin
          if(saved_write) begin
            memory[saved_address]<=saved_data;
            $fwrite(outfd,"%0d %0d %h\n",case_id,saved_address,saved_data);
          end
          memory_response_data<=memory[saved_address];memory_response_valid<=1;pending<=0;
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
      for(i=0;i<8192;i=i+1) memory[i]=32'h7fc00000;
      n=$fscanf(fd,"%d %h %d\n",case_id,command_data,words);if(n!=3) $fatal(1,"header");
      for(i=0;i<words;i=i+1) begin
        n=$fscanf(fd,"%d %h\n",address,datum);if(n!=2) $fatal(1,"input");memory[address]=datum;
      end
      if(!command_ready) $fatal(1,"not ready");
      command_valid=1;@(negedge clk);command_valid=0;deadline=0;
      while(!completion_valid) begin
        @(negedge clk);deadline=deadline+1;if(deadline>1000000) $fatal(1,"timeout");
      end
      if(completion_error||completion_tag!=case_id||pending||memory_response_valid)
        $fatal(1,"completion error or uncommitted write");
      repeat(3) @(negedge clk);
      completion_ready=1;@(negedge clk);completion_ready=0;
    end
    command_data[384+:32]=3;command_valid=1;@(negedge clk);command_valid=0;
    repeat(5) @(negedge clk);
    if(!completion_valid||!completion_error||memory_valid) $fatal(1,"invalid geometry");
    $fclose(outfd);$display("PASS head dispatcher: grouped-query attention, recurrent heads, committed writes, invalid dimensions");$finish;
  end
endmodule
