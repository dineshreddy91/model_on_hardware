`timescale 1ns/1ps

module tb_openjev_int8_dot_tile;
localparam int OUTPUT_LANES = 4;
localparam int K_LANES = 32;
localparam int BEATS = 4;

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
integer expected [0:OUTPUT_LANES-1];
integer beat;
integer output_lane;
integer k_lane;
integer activation;
integer weight;
integer failures = 0;

always #2 clk = ~clk;

openjev_int8_dot_tile #(
  .OUTPUT_LANES(OUTPUT_LANES),
  .K_LANES(K_LANES)
) dut (.*);

initial begin
  for (output_lane = 0; output_lane < OUTPUT_LANES; output_lane = output_lane + 1)
    expected[output_lane] = 0;
  repeat (4) @(posedge clk);
  rst_n <= 1'b1;
  @(posedge clk);
  start <= 1'b1;
  @(posedge clk);
  start <= 1'b0;

  for (beat = 0; beat < BEATS; beat = beat + 1) begin
    while (!input_ready) @(posedge clk);
    for (k_lane = 0; k_lane < K_LANES; k_lane = k_lane + 1) begin
      activation = ((beat*K_LANES+k_lane) % 17) - 8;
      activation_data[k_lane*8 +: 8] = activation;
      for (output_lane = 0; output_lane < OUTPUT_LANES; output_lane = output_lane + 1) begin
        weight = ((output_lane*7+k_lane*3+beat) % 13) - 6;
        weight_data[(output_lane*K_LANES+k_lane)*8 +: 8] = weight;
        expected[output_lane] = expected[output_lane] + activation * weight;
      end
    end
    input_last <= beat == BEATS-1;
    input_valid <= 1'b1;
    @(posedge clk);
    input_valid <= 1'b0;
    input_last <= 1'b0;
  end

  wait (done);
  #1;
  for (output_lane = 0; output_lane < OUTPUT_LANES; output_lane = output_lane + 1) begin
    if ($signed(result_data[output_lane*32 +: 32]) !== expected[output_lane]) begin
      $display("FAIL lane=%0d actual=%0d expected=%0d", output_lane,
               $signed(result_data[output_lane*32 +: 32]), expected[output_lane]);
      failures = failures + 1;
    end else begin
      $display("PASS lane=%0d result=%0d", output_lane, expected[output_lane]);
    end
  end
  if (failures != 0) $fatal(1, "%0d failures", failures);
  $display("OPENJEV_INT8_DOT_TILE_PASS");
  $finish;
end

initial begin
  #10000;
  $fatal(1, "timeout");
end

endmodule
