`timescale 1ns/1ps

// Exact INT32 * binary16 -> binary32 with one ties-to-even rounding.
// Registered arithmetic boundaries preserve timing for full-model integration.
module openjev_scaled_int32 (
  input logic clk, rst_n,
  input logic input_valid,
  output logic input_ready,
  input logic signed [31:0] accumulator,
  input logic [15:0] scale,
  output logic output_valid,
  input logic output_ready,
  output logic [31:0] output_data,
  output logic output_error
);
  typedef enum logic [2:0] {IDLE, MULTIPLY, LOCATE, ALIGN, ROUND, PACK, RESULT} state_t;
  state_t state;
  logic [31:0] magnitude;
  logic [10:0] significand;
  logic [42:0] product;
  logic sign_bit, invalid, zero_product;
  logic signed [9:0] scale_exponent, exponent_value;
  logic [5:0] leading, leading_q;
  logic [24:0] rounded, aligned;
  logic increment;
  logic [42:0] remainder_bits, halfway;
  logic [24:0] alignment;
  integer shift_count;

  assign input_ready = rst_n && state == IDLE;
  assign output_valid = rst_n && state == RESULT;
  always_comb begin
    leading = 0;
    for (integer i=0; i<43; i=i+1)
      if (product[i]) leading=6'(i);
    shift_count = int'(leading_q)-23;
    remainder_bits=0; halfway=0; alignment=0;
    if (shift_count>0) begin
      alignment=25'(product >> shift_count);
      remainder_bits=product & ((43'd1 << shift_count)-1);
      halfway=43'd1 << (shift_count-1);
    end else alignment=25'(product << (-shift_count));
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state<=IDLE; output_data<=0; output_error<=0;
      magnitude<=0; significand<=0; product<=0; sign_bit<=0; invalid<=0;
      scale_exponent<=0; exponent_value<=0; leading_q<=0; aligned<=0;
      rounded<=0; increment<=0; zero_product<=0;
    end else case (state)
      IDLE: if (input_valid) begin
        magnitude<=accumulator[31] ? (~accumulator+32'd1) : accumulator;
        significand<={scale[14:10]!=0,scale[9:0]};
        sign_bit<=accumulator[31]^scale[15];
        invalid<=scale[14:10]==31;
        scale_exponent<=scale[14:10]==0 ? -10'sd24 : $signed({5'b0,scale[14:10]})-10'sd25;
        state<=MULTIPLY;
      end
      MULTIPLY: begin product<=magnitude*significand; state<=LOCATE; end
      LOCATE: begin
        leading_q<=leading; zero_product<=product==0;
        exponent_value<=scale_exponent+$signed({4'b0,leading})+10'sd127;
        state<=ALIGN;
      end
      ALIGN: begin
        aligned<=alignment;
        increment<=shift_count>0 && (remainder_bits>halfway || (remainder_bits==halfway && alignment[0]));
        state<=ROUND;
      end
      ROUND: begin rounded<=aligned+25'(increment); state<=PACK; end
      PACK: begin
        output_error<=invalid;
        if (invalid) output_data<=0;
        else if (zero_product) output_data<={sign_bit,31'b0};
        else if (rounded[24]) output_data<={sign_bit,8'(exponent_value+10'sd1),rounded[23:1]};
        else output_data<={sign_bit,exponent_value[7:0],rounded[22:0]};
        state<=RESULT;
      end
      RESULT: if (output_ready) state<=IDLE;
      default: state<=IDLE;
    endcase
  end
endmodule
