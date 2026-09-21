module openjev_head_rom (
  input  logic clk,
  input  logic [9:0] index,
  output logic signed [7:0] weight0,
  output logic signed [7:0] weight1,
  output logic signed [7:0] weight2
);

(* rom_style = "block" *) logic [7:0] weight0_mem [0:1023];
(* rom_style = "block" *) logic [7:0] weight1_mem [0:1023];
(* rom_style = "block" *) logic [7:0] weight2_mem [0:1023];

initial begin
  $readmemh("openjev_weight0.mem", weight0_mem);
  $readmemh("openjev_weight1.mem", weight1_mem);
  $readmemh("openjev_weight2.mem", weight2_mem);
end

always_ff @(posedge clk) begin
  weight0 <= weight0_mem[index];
  weight1 <= weight1_mem[index];
  weight2 <= weight2_mem[index];
end

endmodule
