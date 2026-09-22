`timescale 1ns/1ps
module tb_openjev_hbm_weight_reader;
  logic clk = 0;
  always #2 clk = ~clk;
  logic rst_n = 0, command_valid = 0, command_ready, command_error;
  logic [28:0] base_address = 0;
  logic [31:0] byte_count = 0;
  logic request_valid, request_ready = 0;
  logic [4:0] request_bank;
  logic [28:0] request_address;
  logic response_valid = 0, response_ready;
  logic [255:0] response_data = 0;
  logic [1:0] response_status = 0;
  logic weight_valid, weight_ready = 0;
  logic [255:0] weight_data;
  logic weight_last, done, fault;
  integer checked = 0;
  openjev_hbm_weight_reader dut (.*);

  task automatic tick;
    @(posedge clk); #1;
  endtask
  task automatic reset_reader;
    @(negedge clk); rst_n = 0; command_valid = 0;
    request_ready = 0; response_valid = 0; weight_ready = 0;
    tick();
    if (fault || weight_valid || request_valid || done) $fatal(1, "Reset failure");
    @(negedge clk); rst_n = 1;
    tick();
  endtask
  task automatic command(input logic [28:0] base, input logic [31:0] bytes);
    @(negedge clk); base_address = base; byte_count = bytes; command_valid = 1;
    tick();
    @(negedge clk); command_valid = 0;
  endtask
  task automatic run_stream(input integer words);
    logic [255:0] expected;
    command(29'h12000, words*32);
    for (integer word = 0; word < words; word = word+1) begin
      while (!request_valid) tick();
      repeat (3) begin
        if (request_bank !== ((word/8)%32) || request_address !== (32'h12000+(word/256)*256+(word%8)*32))
          $fatal(1, "Address mismatch at word %0d bank=%0d address=%h", word, request_bank, request_address);
        tick();
      end
      @(negedge clk); request_ready = 1;
      tick();
      @(negedge clk); request_ready = 0;
      repeat (word%4) tick();
      for (integer lane=0; lane<32; lane=lane+1) expected[lane*8 +: 8] = (word*73+lane)%256;
      @(negedge clk); response_data = expected; response_status = 0; response_valid = 1;
      if (!response_ready) $fatal(1, "Response not accepted");
      tick();
      @(negedge clk); response_valid = 0;
      repeat (3) begin
        if (!weight_valid || weight_data !== expected || weight_last !== (word == words-1))
          $fatal(1, "Weight mismatch under backpressure");
        if (request_valid || response_ready || done) $fatal(1, "Unexpected overlap");
        tick();
      end
      @(negedge clk); weight_ready = 1;
      tick();
      if (done !== (word == words-1)) $fatal(1, "Bad completion");
      @(negedge clk); weight_ready = 0;
      checked = checked + 1;
    end
  endtask
  initial begin
    reset_reader();
    command(0, 0); if (!command_error) $fatal(1, "Zero count accepted");
    command(1, 32); if (!command_error) $fatal(1, "Unaligned base accepted");
    command(0, 33); if (!command_error) $fatal(1, "Partial beat accepted");
    command(29'h1ffff000, 32'h100000); if (!command_error) $fatal(1, "Capacity overflow accepted");
    run_stream(1);
    run_stream(257);
    run_stream(1027);
    for (integer error_code=1; error_code<4; error_code=error_code+1) begin
      command(0, 32);
      @(negedge clk); request_ready = 1;
      tick();
      @(negedge clk); request_ready = 0; response_valid = 1; response_status = error_code;
      tick();
      @(negedge clk); response_valid = 0;
      repeat (4) begin
        if (!fault || done || weight_valid || request_valid || command_ready) $fatal(1, "Error did not latch fault");
        tick();
      end
      reset_reader();
    end
    run_stream(9);
    $display("PASS HBM reader: %0d beats, all 32 banks, stripe boundaries, stalled requests/responses/output, rejection and memory faults", checked);
    $finish;
  end
  initial begin
    repeat (100000) @(posedge clk);
    $fatal(1, "Timeout");
  end
endmodule
