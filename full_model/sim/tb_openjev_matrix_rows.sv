`timescale 1ns/1ps
module tb_openjev_matrix_rows #(parameter integer LANES=2);
  reg [65535:0] seen;
  reg clk=0,rst_n=0,command_valid=0;
  always #5 clk=~clk;
  wire command_ready,memory_valid,memory_write,memory_response_ready,done,fault;
  reg [31:0] batch_count=0,rows=0,columns=0,weight_base=4096,source=0,destination=1;
  wire [31:0] memory_tensor,memory_index,memory_data;
  reg memory_ready=0,memory_response_valid=0,memory_response_error=0;
  reg [31:0] memory_response_data=0;
  wire weight_request_valid,weight_response_ready;
  reg weight_request_ready=0,weight_response_valid=0;
  wire [4:0] weight_bank;
  wire [28:0] weight_address;
  reg [255:0] weight_response_data=0;
  reg [1:0] weight_response_status=0;
  reg pending=0,wpending=0,wr;
  reg [31:0] tid,index,data;
  integer cycle=0,delay_count=0,wdelay=0,weight_offset=0,writes=0,requests=0;
  integer lane,j,expected,row,batch,deadline,case_id,total=0;
  generate if(LANES==0) begin: serial
    openjev_matrix_rows_lane dut(.*);
  end else begin: parallel
    openjev_matrix_rows #(.PARALLEL_BATCHES(LANES)) dut(.*);
  end endgenerate
  function integer activation(input integer index); activation=(index*3+4)%255-127;endfunction
  function integer weight(input integer index); weight=(index*13+7)%255-127;endfunction
  always @(posedge clk) begin
    if(!rst_n) begin
      cycle<=0;pending<=0;wpending<=0;memory_ready<=0;memory_response_valid<=0;
      weight_request_ready<=0;weight_response_valid<=0;
    end else begin
      cycle<=cycle+1;
      memory_ready<=!pending&&!memory_response_valid&&cycle%3!=0;
      weight_request_ready<=!wpending&&!weight_response_valid&&cycle%5!=0;
      if(memory_valid&&memory_ready) begin
        tid<=memory_tensor;index<=memory_index;data<=memory_data;wr<=memory_write;pending<=1;delay_count<=4;
      end
      if(pending) begin
        if(delay_count>0) delay_count<=delay_count-1;
        else begin
          if(wr) begin
            if(tid!=1||index>=batch_count*rows||seen[index]) $fatal(1,"matrix output address");
            row=index%rows;batch=index/rows;expected=0;
            for(j=0;j<columns;j=j+1) expected=expected+activation(batch*columns+j)*weight(row*columns+j);
            if(data!==32'(expected)) $fatal(1,"matrix mismatch index %0d got %h expected %h",index,data,expected);
            seen[index]<=1;writes<=writes+1;total<=total+1;
          end else begin
            if(tid!=0||index>=batch_count*columns) $fatal(1,"activation bounds");
            memory_response_data<=activation(index)&255;
          end
          memory_response_valid<=1;pending<=0;
        end
      end
      if(memory_response_valid&&memory_response_ready) memory_response_valid<=0;
      if(weight_request_valid&&weight_request_ready) begin
        if(weight_address<weight_base||weight_address[4:0]!=0) $fatal(1,"weight alignment");
        weight_offset<=((weight_address-weight_base)>>8)*8192+weight_bank*256+weight_address[7:0];
        requests<=requests+1;wpending<=1;wdelay<=5;
      end
      if(wpending) begin
        if(wdelay>0) wdelay<=wdelay-1;
        else begin
          if(weight_offset+32>rows*columns) $fatal(1,"weight bounds");
          for(lane=0;lane<32;lane=lane+1) weight_response_data[lane*8+:8]<=8'(weight(weight_offset+lane));
          weight_response_valid<=1;wpending<=0;
        end
      end
      if(weight_response_valid&&weight_response_ready) weight_response_valid<=0;
    end
  end
  task run_case(input integer batches,m,n);
    begin
      batch_count=batches;rows=m;columns=n;writes=0;requests=0;seen=0;
      command_valid=1;@(negedge clk);command_valid=0;deadline=0;
      while(!done) begin @(negedge clk);deadline=deadline+1;if(fault||deadline>3000000) $fatal(1,"matrix failed");end
      if(writes!=batches*m||requests!=((LANES==0?batches:(batches+LANES-1)/LANES)*m*n/32)||pending||memory_response_valid||wpending||weight_response_valid)
        $fatal(1,"matrix early completion or missing weights");
      $display("MATRIX_PERF lanes=%0d batches=%0d rows=%0d columns=%0d cycles=%0d weight_reads=%0d",LANES,batches,m,n,deadline,requests);
    end
  endtask
  task run_fault(input integer on_weights);
    begin
      rst_n=0;command_valid=0;memory_response_error=0;weight_response_status=0;
      repeat(3)@(negedge clk);rst_n=1;@(negedge clk);
      batch_count=2;rows=3;columns=32;writes=0;requests=0;seen=0;
      if(on_weights)weight_response_status=2;else memory_response_error=1;
      command_valid=1;@(negedge clk);command_valid=0;deadline=0;
      while(!fault)begin @(negedge clk);deadline=deadline+1;if(done||deadline>10000)$fatal(1,"matrix fault not propagated");end
      repeat(5)begin @(negedge clk);if(!fault||done||memory_valid||weight_request_valid)$fatal(1,"matrix fault not contained");end
      rst_n=0;memory_response_error=0;weight_response_status=0;
      repeat(3)@(negedge clk);rst_n=1;@(negedge clk);
      if(!command_ready||fault)$fatal(1,"matrix failed reset recovery");
    end
  endtask
  initial begin
    repeat(3) @(negedge clk);rst_n=1;@(negedge clk);
    run_case(3,20,64);run_case(2,3,1024);run_case(1,6144,32);run_case(4,128,256);run_case(5,7,4096);run_case(4,1024,1024);
    run_fault(0);run_fault(1);run_case(2,2,32);
    columns=33;command_valid=1;@(negedge clk);command_valid=0;
    if(!fault||memory_valid||weight_request_valid) $fatal(1,"invalid columns accepted");
    $display("PASS batched HBM matrix: %0d exact INT32 outputs, striped weights, stalls, committed writes, invalid shape",total);$finish;
  end
endmodule
