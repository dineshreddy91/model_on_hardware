`timescale 1ns/1ps

module openjev_int8_dot_tile #(
  parameter int OUTPUT_LANES = 8,
  parameter int K_LANES = 32
) (
  input  logic                              clk,
  input  logic                              rst_n,
  input  logic                              start,
  input  logic                              input_valid,
  input  logic                              input_last,
  input  logic [K_LANES*8-1:0]              activation_data,
  input  logic [OUTPUT_LANES*K_LANES*8-1:0] weight_data,
  output logic                              input_ready,
  output logic                              busy,
  output logic                              done,
  output logic [OUTPUT_LANES*32-1:0]         result_data
);

logic signed [31:0] dot_product [0:OUTPUT_LANES-1];
logic signed [31:0] accumulator [0:OUTPUT_LANES-1];
integer comb_output_lane;
integer comb_k_lane;
integer seq_output_lane;

always_comb begin
  for (comb_output_lane = 0; comb_output_lane < OUTPUT_LANES; comb_output_lane = comb_output_lane + 1) begin
    dot_product[comb_output_lane] = 32'sd0;
    for (comb_k_lane = 0; comb_k_lane < K_LANES; comb_k_lane = comb_k_lane + 1) begin
      dot_product[comb_output_lane] = dot_product[comb_output_lane]
        + $signed(activation_data[comb_k_lane*8 +: 8])
        * $signed(weight_data[(comb_output_lane*K_LANES+comb_k_lane)*8 +: 8]);
    end
  end
end

assign input_ready = busy;

always_ff @(posedge clk) begin
  if (!rst_n) begin
    busy <= 1'b0;
    done <= 1'b0;
    result_data <= '0;
    for (seq_output_lane = 0; seq_output_lane < OUTPUT_LANES; seq_output_lane = seq_output_lane + 1)
      accumulator[seq_output_lane] <= 32'sd0;
  end else begin
    done <= 1'b0;
    if (start && !busy) begin
      busy <= 1'b1;
      for (seq_output_lane = 0; seq_output_lane < OUTPUT_LANES; seq_output_lane = seq_output_lane + 1)
        accumulator[seq_output_lane] <= 32'sd0;
    end else if (input_valid && input_ready) begin
      for (seq_output_lane = 0; seq_output_lane < OUTPUT_LANES; seq_output_lane = seq_output_lane + 1) begin
        accumulator[seq_output_lane] <= accumulator[seq_output_lane] + dot_product[seq_output_lane];
        if (input_last)
          result_data[seq_output_lane*32 +: 32] <= accumulator[seq_output_lane] + dot_product[seq_output_lane];
      end
      if (input_last) begin
        busy <= 1'b0;
        done <= 1'b1;
      end
    end
  end
end

endmodule
