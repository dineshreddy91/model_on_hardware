`timescale 1ns/1ps
// Dynamic symmetric INT8 row quantization, RNE and saturation to [-127,127].
// scale = max(fp32(absmax * fp32(1/127)), minimum normal FP32), or 1 for a zero row.
// Emit the FP32 scale first, followed by signed INT8 payloads in low eight bits.
module openjev_quantize_row #(
  parameter integer MAX_LENGTH=4096,
  parameter integer WATCHDOG_CYCLES=10000000
)(
  input wire clk,rst_n,command_valid,
  output wire command_ready,
  output reg command_error,
  input wire [31:0] length,
  input wire input_valid,
  output wire input_ready,
  input wire [31:0] input_data,
  input wire input_last,
  output wire output_valid,
  input wire output_ready,
  output wire output_scale,
  output wire [31:0] output_index,
  output wire [31:0] output_data,
  output wire output_last,
  output reg done,
  output wire fault
);
  import openjev_fp32_pkg::*;
  localparam IDLE=0,LOAD=1,SCALE_START=2,ISSUE=3,WAIT_ALU=4,SCALE_SAVE=5,
    INVERSE_SAVE=6,EMIT_SCALE=7,FETCH=8,MULTIPLY=9,ROUND=10,EMIT_VALUE=11,FAILED=12,ROUND_ALIGN=13,ROUND_INCREMENT=14,ROUND_SIGN=15;
  reg [3:0] state,return_state,operation;
  reg [31:0] data[0:MAX_LENGTH-1];
  reg [31:0] count,index,maximum,scale,inverse,value,a,b,result_q,cycles;
  reg [7:0] quantized;
  wire ready,valid,error;
  wire [31:0] result;
  reg quantize_sign;
  reg [4:0] quantize_shift;
  reg [23:0] quantize_mantissa,quantize_remainder,quantize_halfway;
  reg [7:0] quantize_integer;
  reg [8:0] quantize_rounded;
  assign command_ready=rst_n&&state==IDLE;
  assign input_ready=rst_n&&state==LOAD;
  assign output_valid=rst_n&&(state==EMIT_SCALE||state==EMIT_VALUE);
  assign output_scale=state==EMIT_SCALE;
  assign output_data=state==EMIT_SCALE ? scale : {24'b0,quantized};
  assign output_index=index;
  assign output_last=state==EMIT_VALUE&&index==count-1;
  assign fault=state==FAILED;
  openjev_scalar scalar(
    .clk(clk),.rst_n(rst_n),.input_valid(state==ISSUE),.input_ready(ready),
    .opcode(operation),.input_a(a),.input_b(b),
    .output_valid(valid),.output_ready(state==WAIT_ALU),.output_data(result),.output_error(error));
  task calculate;
    input [3:0] op;
    input [31:0] lhs,rhs;
    input [3:0] next_state;
    begin operation<=op;a<=lhs;b<=rhs;return_state<=next_state;state<=ISSUE;end
  endtask
  always @(posedge clk) begin
    if(!rst_n) begin
      state<=IDLE;return_state<=IDLE;operation<=0;count<=0;index<=0;maximum<=0;
      scale<=0;inverse<=0;value<=0;a<=0;b<=0;result_q<=0;cycles<=0;quantized<=0;
      command_error<=0;done<=0;quantize_sign<=0;quantize_shift<=0;quantize_mantissa<=0;
      quantize_remainder<=0;quantize_halfway<=0;quantize_integer<=0;quantize_rounded<=0;
    end else begin
      command_error<=0;done<=0;
      case(state)
        IDLE: if(command_valid) begin
          if(length==0||length>MAX_LENGTH) command_error<=1;
          else begin count<=length;index<=0;maximum<=0;cycles<=0;state<=LOAD;end
        end
        LOAD: if(input_valid) begin
          if(!finite(input_data)||input_last!=(index==count-1)) state<=FAILED;
          else begin
            data[index]<=input_data;
            if(input_data[30:0]>maximum) maximum<={1'b0,input_data[30:0]};
            if(index==count-1) begin index<=0;state<=SCALE_START;end
            else index<=index+1;
          end
        end
        SCALE_START: begin
          if(maximum==0) begin scale<=32'h3f800000;inverse<=32'h3f800000;state<=EMIT_SCALE;end
          else calculate(1,maximum,32'h3c010204,SCALE_SAVE);
        end
        ISSUE: if(ready) state<=WAIT_ALU;
        WAIT_ALU: if(valid) begin
          if(error) state<=FAILED;
          else begin result_q<=result;state<=return_state;end
        end
        SCALE_SAVE: begin
          scale<=result_q<32'h00800000 ? 32'h00800000 : result_q;
          calculate(3,result_q<32'h00800000 ? 32'h00800000 : result_q,0,INVERSE_SAVE);
        end
        INVERSE_SAVE: begin inverse<=result_q;state<=EMIT_SCALE;end
        EMIT_SCALE: if(output_ready) state<=FETCH;
        FETCH: begin value<=data[index];state<=MULTIPLY;end
        MULTIPLY: calculate(1,value,inverse,ROUND);
        ROUND: begin
          quantize_sign<=result_q[31];
          if(result_q[30:23]<126) begin quantized<=0;state<=EMIT_VALUE;end
          else if(result_q[30:23]>=134) begin quantized<=result_q[31] ? 8'h81 : 8'h7f;state<=EMIT_VALUE;end
          else begin
            quantize_shift<=5'(150-result_q[30:23]);
            quantize_mantissa<={1'b1,result_q[22:0]};state<=ROUND_ALIGN;
          end
        end
        ROUND_ALIGN: begin
          quantize_integer<=8'(quantize_mantissa>>quantize_shift);
          quantize_remainder<=quantize_mantissa & 24'((25'd1<<quantize_shift)-1);
          quantize_halfway<=24'd1<<(quantize_shift-1);state<=ROUND_INCREMENT;
        end
        ROUND_INCREMENT: begin
          quantize_rounded<={1'b0,quantize_integer}+9'(quantize_remainder>quantize_halfway ||
            (quantize_remainder==quantize_halfway&&quantize_integer[0]));state<=ROUND_SIGN;
        end
        ROUND_SIGN: begin
          if(quantize_rounded>=127) quantized<=quantize_sign ? 8'h81 : 8'h7f;
          else quantized<=quantize_sign ? -quantize_rounded[7:0] : quantize_rounded[7:0];
          state<=EMIT_VALUE;
        end
        EMIT_VALUE: if(output_ready) begin
          if(index==count-1) begin done<=1;state<=IDLE;end
          else begin index<=index+1;state<=FETCH;end
        end
        FAILED: state<=FAILED;
        default: state<=FAILED;
      endcase
      if(state!=IDLE&&state!=FAILED) begin
        cycles<=cycles+1;
        if(cycles>=WATCHDOG_CYCLES-1) begin state<=FAILED;done<=0;end
      end
    end
  end
endmodule
