`timescale 1ns/1ps
// Softplus and erf-based GELU. Fixed polynomial approximations, FP32 arithmetic.
// Opcode 0: log(1+exp(x)); 1: x*Phi(x). No tanh substitution for the merger.
module openjev_special(
  input wire clk,rst_n,input_valid,
  output wire input_ready,
  input wire opcode,
  input wire [31:0] input_data,
  output wire output_valid,
  input wire output_ready,
  output reg [31:0] output_data,
  output reg output_error
);
  import openjev_fp32_pkg::*;
  localparam IDLE=0,ISSUE=1,WAIT_ALU=2,SP_EXP=3,SP_DENOM=4,SP_INV=5,SP_T=6,
    SQUARE=7,HORNER_MUL=8,HORNER_ADD=9,HORNER_NEXT=10,SP_TIMES_T=11,SP_DOUBLE=12,
    SP_ADD=13,G_Z=14,G_P=15,G_DENOM=16,G_INV=17,G_T=18,G_TIMES_T=19,
    G_ZSQUARE=20,G_EXP=21,G_SCALE=22,G_HALF=23,G_X=24,G_POSITIVE=25,FINISH=26,RESULT=27;
  reg [4:0] state,return_state;
  reg [31:0] x,z,t,square,poly,exponential,value,operand_a,operand_b;
  reg [3:0] operation;
  reg [2:0] coefficient;
  reg kind;
  wire ready,valid,error;
  wire [31:0] result;
  reg [31:0] coefficient_value;
  assign input_ready=rst_n && state==IDLE;
  assign output_valid=rst_n && state==RESULT;
  openjev_scalar arithmetic(
    .clk(clk),.rst_n(rst_n),.input_valid(state==ISSUE),.input_ready(ready),
    .opcode(operation),.input_a(operand_a),.input_b(operand_b),
    .output_valid(valid),.output_ready(state==WAIT_ALU),.output_data(result),.output_error(error));
  always @* begin
    if(kind) case(coefficient)
      3: coefficient_value=32'hbfba00e3;
      2: coefficient_value=32'h3fb5f0e3;
      1: coefficient_value=32'hbe91a98e;
      default: coefficient_value=32'h3e827906;
    endcase
    else case(coefficient)
      6: coefficient_value=32'h3d9d89d9;
      5: coefficient_value=32'h3dba2e8c;
      4: coefficient_value=32'h3de38e39;
      3: coefficient_value=32'h3e124925;
      2: coefficient_value=32'h3e4ccccd;
      1: coefficient_value=32'h3eaaaaab;
      default: coefficient_value=32'h3f800000;
    endcase
  end
  task calculate;
    input [3:0] op;
    input [31:0] a,b;
    input [4:0] next_state;
    begin operation<=op;operand_a<=a;operand_b<=b;return_state<=next_state;state<=ISSUE;end
  endtask
  always @(posedge clk) begin
    if(!rst_n) begin
      state<=IDLE;return_state<=IDLE;x<=0;z<=0;t<=0;square<=0;poly<=0;
      exponential<=0;value<=0;operand_a<=0;operand_b<=0;operation<=0;
      coefficient<=0;kind<=0;output_data<=0;output_error<=0;
    end else case(state)
      IDLE: if(input_valid) begin
        x<=input_data;kind<=opcode;output_error<=0;output_data<=0;
        if(!finite(input_data)) begin output_error<=1;state<=RESULT;end
        else if(opcode && input_data[30:0]>32'h41400000) begin
          output_data<=input_data[31] ? 32'h80000000 : input_data;state<=RESULT;
        end else if(opcode) calculate(1,{1'b0,input_data[30:0]},32'h3f3504f3,G_Z);
        else calculate(2,{1'b1,input_data[30:0]},0,SP_EXP);
      end
      ISSUE: if(ready) state<=WAIT_ALU;
      WAIT_ALU: if(valid) begin
        if(error) begin output_error<=1;output_data<=0;state<=RESULT;end
        else begin value<=result;state<=return_state;end
      end
      SP_EXP: begin exponential<=value;calculate(0,32'h40000000,value,SP_DENOM);end
      SP_DENOM: calculate(3,value,0,SP_INV);
      SP_INV: calculate(1,exponential,value,SP_T);
      SP_T: begin t<=value;calculate(1,value,value,SQUARE);end
      SQUARE: begin square<=value;poly<=32'h3d888889;coefficient<=6;state<=HORNER_MUL;end
      HORNER_MUL: calculate(1,poly,kind ? t : square,HORNER_ADD);
      HORNER_ADD: calculate(0,value,coefficient_value,HORNER_NEXT);
      HORNER_NEXT: begin
        poly<=value;
        if(coefficient==0) begin
          if(kind) state<=G_TIMES_T;else state<=SP_TIMES_T;
        end else begin coefficient<=coefficient-1;state<=HORNER_MUL;end
      end
      SP_TIMES_T: calculate(1,poly,t,SP_DOUBLE);
      SP_DOUBLE: calculate(1,value,32'h40000000,SP_ADD);
      SP_ADD: calculate(0,value,x[31] ? 32'b0 : x,FINISH);
      G_Z: begin z<=value;calculate(1,value,32'h3ea7ba05,G_P);end
      G_P: calculate(0,value,32'h3f800000,G_DENOM);
      G_DENOM: calculate(3,value,0,G_INV);
      G_INV: begin t<=value;poly<=32'h3f87dc22;coefficient<=3;state<=HORNER_MUL;end
      G_TIMES_T: calculate(1,poly,t,G_ZSQUARE);
      G_ZSQUARE: begin poly<=value;calculate(1,z,z,G_EXP);end
      G_EXP: calculate(2,{1'b1,value[30:0]},0,G_SCALE);
      G_SCALE: calculate(1,value,poly,G_HALF);
      G_HALF: calculate(1,value,32'h3f000000,G_X);
      G_X: calculate(1,value,x,G_POSITIVE);
      G_POSITIVE: begin
        if(x[31]) state<=FINISH;
        else calculate(0,x,{~value[31],value[30:0]},FINISH);
      end
      FINISH: begin output_data<=value;state<=RESULT;end
      RESULT: if(output_ready) state<=IDLE;
      default: begin output_error<=1;output_data<=0;state<=RESULT;end
    endcase
  end
endmodule
