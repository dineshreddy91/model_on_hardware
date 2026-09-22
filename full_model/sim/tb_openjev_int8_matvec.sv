`timescale 1ns/1ps
module tb_openjev_int8_matvec;
  `include "dimensions.svh"
  localparam int LANES = 32;
  localparam int WORDS = (COLS + LANES - 1) / LANES;
  logic clk = 0;
  always #2 clk = ~clk;
  logic rst_n = 0, command_valid = 0, command_ready, command_error;
  logic [31:0] columns = 0, rows = 0;
  logic activation_valid = 0, activation_ready, weight_valid = 0, weight_ready;
  logic [255:0] activation_data = 0, weight_data = 0;
  logic result_valid, result_ready = 0, result_last, busy, done;
  logic signed [31:0] result_data;
  logic [31:0] result_row;
  logic [255:0] fixture_a [0:WORDS-1];
  logic [255:0] fixture_w [0:ROWS*WORDS-1];
  logic [31:0] fixture_y [0:ROWS-1];
  integer checked = 0;
  logic fixture_mode = 0, reader_command = 0, reader_command_ready, reader_error;
  logic request_valid, request_ready;
  logic [4:0] request_bank;
  logic [28:0] request_address;
  logic response_valid = 0, response_ready;
  logic [255:0] response_data = 0, reader_data;
  logic reader_valid, reader_last, reader_done, reader_fault;
  integer memory_word = 0, memory_delay = 0, memory_cycle = 0;
  openjev_int8_matvec dut (
    .weight_valid(fixture_mode ? reader_valid : weight_valid),
    .weight_data(fixture_mode ? reader_data : weight_data), .*);
  openjev_hbm_weight_reader reader (
    .clk(clk), .rst_n(rst_n), .command_valid(reader_command),
    .command_ready(reader_command_ready), .command_error(reader_error),
    .base_address(29'h12000), .byte_count(ROWS*COLS),
    .request_valid(request_valid), .request_ready(request_ready),
    .request_bank(request_bank), .request_address(request_address),
    .response_valid(response_valid), .response_ready(response_ready),
    .response_data(response_data), .response_status(2'b00),
    .weight_valid(reader_valid), .weight_ready(fixture_mode && weight_ready),
    .weight_data(reader_data), .weight_last(reader_last),
    .done(reader_done), .fault(reader_fault));
  assign request_ready = rst_n && memory_delay == 0 && !response_valid && memory_cycle%3 != 0;

  // Independently model 32-bank reads with delayed responses and address stalls.
  always @(posedge clk) begin
    if (!rst_n) begin
      memory_word <= 0;
      memory_delay <= 0;
      memory_cycle <= 0;
      response_valid <= 0;
    end else begin
      memory_cycle <= memory_cycle + 1;
      if (request_valid && request_ready) begin
        if (request_bank !== ((memory_word/8)%32) ||
            request_address !== (32'h12000+(memory_word/256)*256+(memory_word%8)*32))
          $fatal(1, "Integrated HBM address mismatch at word %0d", memory_word);
        if (memory_word >= ROWS*WORDS) $fatal(1, "Extra memory read");
        response_data <= fixture_w[memory_word];
        memory_word <= memory_word + 1;
        memory_delay <= 1 + memory_word%4;
      end
      if (memory_delay > 0) begin
        memory_delay <= memory_delay - 1;
        if (memory_delay == 1) response_valid <= 1;
      end
      if (response_valid && response_ready) response_valid <= 0;
      if (reader_fault || reader_error) $fatal(1, "Reader unexpectedly faulted");
    end
  end

  task automatic tick;
    @(posedge clk); #1;
  endtask

  task automatic reset_engine;
    @(negedge clk);
    rst_n = 0;
    activation_valid = 0;
    weight_valid = 0;
    command_valid = 0;
    result_ready = 0;
    tick();
    if (busy || result_valid || done) $fatal(1, "Reset did not cancel transaction");
    @(negedge clk); rst_n = 1;
    tick();
    if (!command_ready) $fatal(1, "No command readiness after reset");
  endtask

  task automatic command(input integer n, input integer m);
    if (!command_ready) $fatal(1, "Engine not ready for command");
    @(negedge clk); columns = n; rows = m; command_valid = 1;
    tick();
    @(negedge clk); command_valid = 0;
  endtask

  task automatic activation(input logic [255:0] data, input integer gap);
    repeat (gap) tick();
    @(negedge clk); activation_data = data; activation_valid = 1;
    while (!activation_ready) @(negedge clk);
    tick();
    @(negedge clk); activation_valid = 0;
  endtask

  task automatic weight(input logic [255:0] data, input integer gap);
    repeat (gap) tick();
    @(negedge clk); weight_data = data; weight_valid = 1;
    while (!weight_ready) @(negedge clk);
    tick();
    @(negedge clk); weight_valid = 0;
  endtask

  task automatic check_result(input integer expected, input integer row_index, input integer total_rows);
    while (!result_valid) tick();
    repeat (4) begin
      if (result_data !== expected || result_row !== row_index || result_last !== (row_index == total_rows-1))
        $fatal(1, "row %0d: got %0d expected %0d, index=%0d last=%0b", row_index, result_data, expected, result_row, result_last);
      if (weight_ready || command_ready || done) $fatal(1, "Invalid state under output backpressure");
      tick();
    end
    @(negedge clk); result_ready = 1;
    tick();
    if (done !== (row_index == total_rows-1)) $fatal(1, "Incorrect done timing");
    @(negedge clk); result_ready = 0;
    checked = checked + 1;
  endtask

  task automatic synthetic(input integer n, input integer m, input integer pattern);
    logic [255:0] data;
    integer a, w, sum, words;
    words = (n+31)/32;
    command(n, m);
    for (integer b = 0; b < words; b = b+1) begin
      data = '1;
      for (integer k = 0; k < 32; k = k+1) begin
        a = pattern == 1 ? -128 : ((b*32+k)*73+19)%256-128;
        data[k*8 +: 8] = a;
      end
      activation(data, b%3);
    end
    for (integer r = 0; r < m; r = r+1) begin
      sum = 0;
      for (integer b = 0; b < words; b = b+1) begin
        data = '1;
        for (integer k = 0; k < 32; k = k+1) begin
          a = pattern == 1 ? -128 : ((b*32+k)*73+19)%256-128;
          w = pattern == 1 ? -128 : ((r*31+b*32+k)*17)%256-128;
          data[k*8 +: 8] = w;
          if (b*32+k < n) sum = sum + a*w;
        end
        weight(data, (r+b)%3);
      end
      check_result(sum, r, m);
    end
  endtask

  initial begin
    $readmemh("activations.mem", fixture_a);
    $readmemh("weights.mem", fixture_w);
    $readmemh("expected.mem", fixture_y);
    reset_engine();
    command(0, 1);
    if (!command_error || busy) $fatal(1, "Zero columns accepted");
    tick();
    command(4097, 1);
    if (!command_error || busy) $fatal(1, "Oversized vector accepted");
    tick();
    command(32, 0);
    if (!command_error || busy) $fatal(1, "Zero rows accepted");
    tick();
    command(32, 2);
    activation('1, 0);
    weight('1, 0);
    reset_engine();
    synthetic(1, 2, 0);
    synthetic(31, 3, 0);
    synthetic(32, 3, 0);
    synthetic(33, 3, 0);
    synthetic(127, 3, 0);
    synthetic(4096, 2, 1);
    command(COLS, ROWS);
    for (integer b = 0; b < WORDS; b = b+1) activation(fixture_a[b], b%3);
    @(negedge clk); fixture_mode = 1; reader_command = 1;
    tick();
    @(negedge clk); reader_command = 0;
    for (integer r = 0; r < ROWS; r = r+1)
      check_result($signed(fixture_y[r]), r, ROWS);
    if (memory_word != ROWS*WORDS || !reader_command_ready) $fatal(1, "Incomplete HBM stream");
    @(negedge clk); fixture_mode = 0;
    // Reset while an unconsumed result is held, then reuse the activation RAM.
    command(32, 1);
    activation('1, 0);
    weight('1, 0);
    while (!result_valid) tick();
    reset_engine();
    synthetic(65, 2, 0);
    $display("PASS matvec: %0d rows checked; real matrix %0d x %0d, tail masks, signed extremes, stalls, backpressure, invalid commands and reset", checked, ROWS, COLS);
    $finish;
  end
  initial begin
    repeat (8000000) @(posedge clk);
    $fatal(1, "Global simulation timeout");
  end
endmodule
