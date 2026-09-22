`timescale 1ns/1ps
// Registered finite FP32 add/multiply, round-to-nearest-even with subnormals.
// Separates alignment, arithmetic, leading-bit detection, shift, round and pack.
module openjev_fp32_alu(
  input wire clk,rst_n,input_valid,
  output wire input_ready,
  input wire multiply,scale_mode,
  input wire signed [31:0] scale_power,
  input wire [31:0] input_a,input_b,
  output wire output_valid,
  input wire output_ready,
  output reg [31:0] output_data
);
  import openjev_fp32_pkg::*;
  localparam IDLE=0,PREP=1,ALIGN=2,ARITH=3,TOP_BYTE=4,TOP_BIT=5,
             EXPONENT=6,SHIFT=7,ROUND=8,PACK=9,RESULT=10;
  reg [3:0] state;
  reg [31:0] a,b,big,smaller;
  reg scale_q;
  integer scale_power_q;
  reg mul,sign_q,same_sign,zero_sign,invalid;
  reg [23:0] ma,mb;
  reg [63:0] lhs,rhs,magnitude,shifted,remainder_bits,halfway,rounded;
  integer eb,es,power,top,exponent_q,shift_count,byte_top;
  reg subnormal;
  integer i;
  assign input_ready=rst_n && state==IDLE;
  assign output_valid=rst_n && state==RESULT;
  always @(posedge clk) begin
    if(!rst_n) begin
      state<=IDLE;scale_q<=0;scale_power_q<=0;a<=0;b<=0;big<=0;smaller<=0;mul<=0;sign_q<=0;same_sign<=0;
      zero_sign<=0;invalid<=0;ma<=0;mb<=0;lhs<=0;rhs<=0;magnitude<=0;
      shifted<=0;remainder_bits<=0;halfway<=0;rounded<=0;eb<=0;es<=0;power<=0;
      top<=0;exponent_q<=0;shift_count<=0;byte_top<=0;subnormal<=0;output_data<=0;
    end else case(state)
      IDLE: if(input_valid) begin
        a<=input_a;b<=input_b;mul<=multiply;scale_q<=scale_mode;scale_power_q<=scale_power;
        big<=input_a[30:0]>=input_b[30:0] ? input_a : input_b;
        smaller<=input_a[30:0]>=input_b[30:0] ? input_b : input_a;
        invalid<=!finite(input_a)||(!scale_mode&&!finite(input_b))||(scale_mode&&(scale_power < -512 || scale_power>512));state<=PREP;
      end
      PREP: begin
        ma<={(a[30:23]!=0),a[22:0]};mb<={(b[30:23]!=0),b[22:0]};
        eb<=big[30:23]==0 ? 1 : int'(big[30:23]);
        es<=smaller[30:23]==0 ? 1 : int'(smaller[30:23]);
        same_sign<=a[31]==b[31];zero_sign<=a[31]&b[31];
        sign_q<=scale_q ? a[31] : mul ? a[31]^b[31] : big[31];
        power<=scale_q ? (a[30:23]==0 ? 1 : int'(a[30:23]))-150+scale_power_q : mul ? (a[30:23]==0 ? 1 : int'(a[30:23]))+
                     (b[30:23]==0 ? 1 : int'(b[30:23]))-300
                   : (big[30:23]==0 ? 1 : int'(big[30:23]))-182;
        state<=ALIGN;
      end
      ALIGN: begin
        lhs<={8'b0,(big[30:23]!=0),big[22:0],32'b0};
        rhs<=shift_jam({8'b0,(smaller[30:23]!=0),smaller[22:0],32'b0},eb-es);
        state<=ARITH;
      end
      ARITH: begin
        magnitude<=scale_q ? {40'b0,ma} : mul ? {16'b0,48'(ma*mb)} : same_sign ? lhs+rhs : lhs-rhs;
        if(!scale_q && !mul && lhs==rhs && !same_sign) sign_q<=zero_sign;
        state<=TOP_BYTE;
      end
      TOP_BYTE: begin
        byte_top<=0;
        for(i=0;i<8;i=i+1) if(|magnitude[i*8+:8]) byte_top<=i;
        state<=TOP_BIT;
      end
      TOP_BIT: begin
        top<=byte_top*8;
        for(i=0;i<8;i=i+1) if(magnitude[byte_top*8+i]) top<=byte_top*8+i;
        state<=EXPONENT;
      end
      EXPONENT: begin
        exponent_q<=top+power;subnormal<=top+power < -126;
        shift_count<=top+power < -126 ? -149-power : top-23;
        state<=SHIFT;
      end
      SHIFT: begin
        if(shift_count<=0) begin shifted<=magnitude<<(-shift_count);remainder_bits<=0;halfway<=0;end
        else if(shift_count>64) begin shifted<=0;remainder_bits<=0;halfway<=0;end
        else begin
          shifted<=shift_count==64 ? 0 : magnitude>>shift_count;
          remainder_bits<=shift_count==64 ? magnitude : magnitude&((64'b1<<shift_count)-1);
          halfway<=64'b1<<(shift_count-1);
        end
        state<=ROUND;
      end
      ROUND: begin
        rounded<=shifted+((halfway!=0)&&((remainder_bits>halfway)||
                  (remainder_bits==halfway&&shifted[0])));
        state<=PACK;
      end
      PACK: begin
        if(invalid) output_data<=32'h7fc00000;
        else if(magnitude==0) output_data<={sign_q,31'b0};
        else if(subnormal) output_data<={sign_q,7'b0,rounded[23:0]};
        else if(exponent_q>127 || (rounded[24]&&exponent_q==127))
          output_data<={sign_q,8'hff,23'b0};
        else if(rounded[24]) output_data<={sign_q,8'(exponent_q+128),rounded[23:1]};
        else output_data<={sign_q,8'(exponent_q+127),rounded[22:0]};
        state<=RESULT;
      end
      RESULT: if(output_ready) state<=IDLE;
      default: state<=IDLE;
    endcase
  end
endmodule
