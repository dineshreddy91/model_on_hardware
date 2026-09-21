`timescale 1ns/1ps

module tb_openjev_real_head_tile;
localparam int OUTPUT_LANES = 3;
localparam int K_LANES = 32;
`include "head_fixture/expected.svh"

logic clk = 1'b0;
logic rst_n = 1'b0;
logic start = 1'b0;
logic input_valid = 1'b0;
logic input_last = 1'b0;
logic [K_LANES*8-1:0] activation_data = '0;
logic [OUTPUT_LANES*K_LANES*8-1:0] weight_data = '0;
logic input_ready;
logic busy;
logic done;
logic [OUTPUT_LANES*32-1:0] result_data;
logic [7:0] activation_mem [0:1023];
logic [7:0] weight0_mem [0:1023];
logic [7:0] weight1_mem [0:1023];
logic [7:0] weight2_mem [0:1023];
integer beat;
integer lane;
integer failures = 0;

always #2 clk = ~clk;

openjev_int8_dot_tile #(.OUTPUT_LANES(OUTPUT_LANES), .K_LANES(K_LANES)) dut (.*);

initial begin
  $readmemh("head_fixture/activation.mem", activation_mem);
  $readmemh("head_fixture/weight0.mem", weight0_mem);
  $readmemh("head_fixture/weight1.mem", weight1_mem);
  $readmemh("head_fixture/weight2.mem", weight2_mem);
  repeat (4) @(posedge clk);
  rst_n <= 1'b1;
  @(posedge clk);
  start <= 1'b1;
  @(posedge clk);
  start <= 1'b0;
  for (beat = 0; beat < 32; beat = beat + 1) begin
    while (!input_ready) @(posedge clk);
    for (lane = 0; lane < K_LANES; lane = lane + 1) begin
      activation_data[lane*8 +: 8] = activation_mem[beat*K_LANES+lane];
      weight_data[(0*K_LANES+lane)*8 +: 8] = weight0_mem[beat*K_LANES+lane];
      weight_data[(1*K_LANES+lane)*8 +: 8] = weight1_mem[beat*K_LANES+lane];
      weight_data[(2*K_LANES+lane)*8 +: 8] = weight2_mem[beat*K_LANES+lane];
    end
    input_last <= beat == 31;
    input_valid <= 1'b1;
    @(posedge clk);
    input_valid <= 1'b0;
    input_last <= 1'b0;
  end
  wait (done);
  #1;
  if ($signed(result_data[0*32 +: 32]) !== EXPECTED0) failures = failures + 1;
  if ($signed(result_data[1*32 +: 32]) !== EXPECTED1) failures = failures + 1;
  if ($signed(result_data[2*32 +: 32]) !== EXPECTED2) failures = failures + 1;
  $display("FPGA_TILE=%0d,%0d,%0d", $signed(result_data[0*32 +: 32]),
           $signed(result_data[1*32 +: 32]), $signed(result_data[2*32 +: 32]));
  $display("EXPECTED=%0d,%0d,%0d", EXPECTED0, EXPECTED1, EXPECTED2);
  if (failures != 0) $fatal(1, "real OpenJEV head mismatch");
  $display("OPENJEV_REAL_HEAD_TILE_PASS");
  $finish;
end

initial begin
  #10000;
  $fatal(1, "timeout");
end

endmodule
