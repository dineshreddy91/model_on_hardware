`timescale 1ns/1ps
module tb_openjev_row_ops;
  reg clk=0,rst_n=0,command_valid=0;
  always #5 clk=~clk;
  wire command_ready,memory_valid,memory_write,memory_response_ready,done,fault;
  reg [7:0] opcode=0;
  reg [23:0] flags=0;
  reg [1:0] dtype0=3,dtype1=3,dtype2=3;
  reg [31:0] row_count=0,row_width=0,epsilon=0;
  reg [31:0] source0=0,source1=1,source2=2,destination0=3,destination1=4;
  wire [31:0] memory_tensor,memory_index,memory_data;
  reg memory_ready=0,memory_response_valid=0,memory_response_error=0;
  reg [31:0] memory_response_data=0;
  reg [31:0] memory[0:4][0:32767];
  reg pending=0,wr;
  reg [31:0] tid,index,data,fixture_word;
  integer cycle=0,delay_count=0,fd,outfd,n,case_id,i,j,count,deadline,writes,expected_writes;
  string path,results;
  openjev_row_ops dut(.*);
  always @(posedge clk) begin
    if(!rst_n) begin cycle<=0;pending<=0;memory_response_valid<=0;memory_ready<=0;end
    else begin
      cycle<=cycle+1;
      memory_ready<=!pending&&!memory_response_valid&&cycle%3!=0;
      if(memory_valid&&memory_ready) begin
        if(memory_tensor>4||memory_index>=32768) $fatal(1,"bounds");
        tid<=memory_tensor;index<=memory_index;data<=memory_data;wr<=memory_write;
        pending<=1;delay_count<=3;
      end
      if(pending) begin
        if(delay_count>0) delay_count<=delay_count-1;
        else begin
          memory_response_data<=memory[tid][index];
          if(wr) begin
            if(tid<3) $fatal(1,"write order");
            memory[tid][index]<=data;writes<=writes+1;
            $fwrite(outfd,"%0d %0d %0d %h\n",case_id,tid,index,data);
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
      n=$fscanf(fd,"%d %d %d %d %d %h %d %d %d\n",case_id,opcode,flags,row_count,row_width,epsilon,dtype0,dtype1,dtype2);if(n!=9) $fatal(1,"header");
      for(j=0;j<3;j=j+1) begin
        n=$fscanf(fd,"%d\n",count);if(n!=1||count>32768) $fatal(1,"length");
        for(i=0;i<count;i=i+1) begin n=$fscanf(fd,"%h\n",fixture_word);memory[j][i]=fixture_word;end
      end
      expected_writes=row_count*row_width+(opcode==1 ? row_count : 0);
      writes=0;command_valid=1;@(negedge clk);command_valid=0;deadline=0;
      while(!done) begin @(negedge clk);deadline=deadline+1;if(fault||deadline>5000000) $fatal(1,"row operator failed");end
      if(writes!=expected_writes||pending||memory_response_valid) $fatal(1,"early completion");
    end
    opcode=4;row_count=1;row_width=1;flags=0;writes=0;memory_response_error=1;
    command_valid=1;@(negedge clk);command_valid=0;deadline=0;
    while(!fault) begin @(negedge clk);deadline=deadline+1;if(done||deadline>1000) $fatal(1,"bus error accepted");end
    if(writes!=0) $fatal(1,"bus error committed");
    $fclose(outfd);$display("PASS row operators: tensor mapping, output stalls, committed writes and bus faults");$finish;
  end
endmodule
