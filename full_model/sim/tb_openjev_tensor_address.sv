`timescale 1ns/1ps
module tb_openjev_tensor_address;
  reg clk=0,rst_n=0,request_valid=0,response_ready=0,request_write=0;
  always #5 clk=~clk;
  reg [1023:0] descriptor=0,root_descriptor=0;
  reg [31:0] element_index=0;
  wire request_ready,response_valid,response_error;
  wire [31:0] base_address,bank_extent,logical_bytes,byte_offset;
  wire [2:0] element_bytes;
  integer i,tests=0,deadline;
  openjev_tensor_address dut(.*);
  task setup;
    begin
      root_descriptor=0;
      root_descriptor[0+:32]=5;root_descriptor[32+:32]=3;root_descriptor[64+:32]=2;
      root_descriptor[96+:32]=2;root_descriptor[128+:32]=32'h02000000;
      root_descriptor[160+:32]=128*4096*4;root_descriptor[192+:32]=5;
      root_descriptor[256+:32]=128;root_descriptor[288+:32]=4096;
      root_descriptor[384+:32]=4096*4;root_descriptor[416+:32]=4;
      root_descriptor[512+:32]=65536;
      descriptor=root_descriptor;descriptor[0+:32]=6;descriptor[64+:32]=3;
      descriptor[96+:32]=3;descriptor[160+:32]=128*8*256*4;descriptor[224+:32]=256*4;
      descriptor[256+:32]=128;descriptor[288+:32]=8;descriptor[320+:32]=256;
      descriptor[384+:32]=4096*4;descriptor[416+:32]=512*4;descriptor[448+:32]=4;
      request_write=0;
    end
  endtask
  task check;
    input [31:0] index,expected;
    input error_expected;
    begin
      @(negedge clk);element_index=index;request_valid=1;
      @(negedge clk);request_valid=0;deadline=0;
      while(!response_valid) begin
        @(negedge clk);deadline=deadline+1;
        if(deadline>200) $fatal(1,"mapping timeout");
      end
      if(response_error!=error_expected || (!error_expected&&byte_offset!=expected))
        $fatal(1,"map index=%d offset=%d expected=%d error=%d",index,byte_offset,expected,response_error);
      repeat(3) @(negedge clk);
      if(!response_valid) $fatal(1,"response not held");
      response_ready=1;@(negedge clk);response_ready=0;tests=tests+1;
    end
  endtask
  initial begin
    repeat(3) @(negedge clk);rst_n=1;setup;
    for(i=0;i<50;i=i+1) check(i*5231,(i*5231/2048)*16384+((i*5231/256)%8)*2048+(i*5231%256)*4+1024,0);
    check(128*8*256-1,127*16384+7*2048+255*4+1024,0);
    check(128*8*256,0,1);
    request_write=1;check(0,0,1);setup;
    descriptor[448+:32]=3;check(0,0,1);setup;
    descriptor[320+:32]=0;check(0,0,1);setup;
    descriptor[224+:32]=32'hfffffff0;check(0,0,1);setup;
    descriptor[192+:32]=7;check(0,0,1);setup;
    descriptor[160+:32]=4;check(0,0,1);setup;
    descriptor=root_descriptor;request_write=1;check(100,400,0);
    // A non-power-of-two rank-four view exercises all restoring dividers.
    setup;root_descriptor[160+:32]=960;
    descriptor=root_descriptor;descriptor[0+:32]=6;descriptor[64+:32]=3;descriptor[96+:32]=4;
    descriptor[160+:32]=960;
    descriptor[256+:32]=2;descriptor[288+:32]=3;descriptor[320+:32]=5;descriptor[352+:32]=8;
    descriptor[384+:32]=480;descriptor[416+:32]=160;descriptor[448+:32]=32;descriptor[480+:32]=4;
    for(i=0;i<240;i=i+7) check(i,i*4,0);
    $display("PASS tensor address: %0d cases, interleaved gates, rank-four strides, bounds and descriptor errors",tests);
    $finish;
  end
endmodule
