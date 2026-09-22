`timescale 1ns/1ps
// Streams FP32 vectors through scalar ops 0..7, RMSNorm=8, LayerNorm=9,
// or stable softmax=10. Norm inputs B/C are affine gamma/beta (RMS ignores C).
// Input framing and numeric faults latch until reset; no partial-success done.
module openjev_vector #(
  parameter integer MAX_LENGTH=4096
)(
  input logic clk,rst_n,command_valid,
  output logic command_ready,command_error,
  input logic [3:0] command_opcode,
  input logic [31:0] command_length,command_epsilon,
  input logic input_valid,
  output logic input_ready,
  input logic [31:0] input_a,input_b,input_c,
  input logic input_last,
  output logic output_valid,
  input logic output_ready,
  output logic [31:0] output_data,
  output logic output_last,
  output logic done,fault
);
  import openjev_fp32_pkg::*;
  typedef enum logic [5:0] {IDLE,LOAD,START,ISSUE,WAIT_RESULT,
    SUM_STEP,SUM_SAVE,MEAN_MULT,MEAN_SAVE,CENTER,CENTER_SAVE,SQUARE,
    VAR_ADD,VAR_SAVE,VAR_MEAN,EPS_ADD,INV_SQRT,FACTOR_SAVE,
    EXP_CENTER,EXP_START,EXP_SAVE,EXP_SUM,EXP_SUM_SAVE,INV_SUM,
    MAP,NORM_GAMMA,NORM_BETA,EMIT,FAULTED} state_t;
  state_t state,return_state;
  logic [31:0] a_mem[0:MAX_LENGTH-1],b_mem[0:MAX_LENGTH-1],c_mem[0:MAX_LENGTH-1];
  logic [31:0] work_mem[0:MAX_LENGTH-1];
  logic [3:0] op,qop;
  logic [31:0] length,index,epsilon,sum,mean,inv_length,factor,maximum,result;
  logic [31:0] qa,qb,scalar_result;
  logic scalar_ready,scalar_valid,scalar_error;
  assign command_ready=rst_n && state==IDLE;
  assign input_ready=rst_n && state==LOAD;
  assign output_valid=rst_n && state==EMIT;
  assign output_data=result;
  assign output_last=index==length-1;
  assign fault=state==FAULTED;
  openjev_scalar scalar_unit(
    .clk(clk),.rst_n(rst_n),.input_valid(state==ISSUE),.input_ready(scalar_ready),
    .opcode(qop),.input_a(qa),.input_b(qb),.output_valid(scalar_valid),
    .output_ready(state==WAIT_RESULT),.output_data(scalar_result),.output_error(scalar_error));

  task automatic invoke(input logic [3:0] operation,
      input logic [31:0] a,b,input state_t next_state);
    begin qop<=operation; qa<=a; qb<=b; return_state<=next_state; state<=ISSUE; end
  endtask

  always_ff @(posedge clk) begin
    if(!rst_n) begin
      state<=IDLE; return_state<=IDLE; command_error<=0; done<=0;
      op<=0; qop<=0; qa<=0; qb<=0; length<=0; index<=0; epsilon<=0;
      sum<=0; mean<=0; inv_length<=0; factor<=0; maximum<=0; result<=0;
    end else begin
      command_error<=0; done<=0;
      case(state)
        IDLE: if(command_valid) begin
          if(command_length==0 || command_length>MAX_LENGTH || command_opcode>10 ||
             (command_opcode>=8 && command_opcode<=9 &&
              (!finite(command_epsilon) || command_epsilon[31] || command_epsilon[30:0]==0)))
            command_error<=1;
          else begin
            op<=command_opcode; length<=command_length; epsilon<=command_epsilon;
            index<=0; sum<=0; mean<=0; maximum<=32'hff7fffff; state<=LOAD;
          end
        end
        LOAD: if(input_valid) begin
          if(!finite(input_a) || ((op<2 || op==8 || op==9) && !finite(input_b)) ||
             (op==9 && !finite(input_c)) || input_last!=(index==length-1)) state<=FAULTED;
          else begin
            a_mem[index]<=input_a; b_mem[index]<=input_b; c_mem[index]<=input_c;
            if(fp_less(maximum,input_a)) maximum<=input_a;
            if(index==length-1) begin index<=0; state<=START; end
            else index<=index+1;
          end
        end
        START: begin
          if(op<8) state<=MAP;
          else if(op==10) state<=EXP_CENTER;
          else invoke(3,fp_from_u13(length[12:0]),0,SUM_STEP);
        end
        ISSUE: if(scalar_ready) state<=WAIT_RESULT;
        WAIT_RESULT: if(scalar_valid) begin
          if(scalar_error) state<=FAULTED;
          else begin result<=scalar_result; state<=return_state; end
        end
        SUM_STEP: begin
          inv_length<=result;
          if(op==8) state<=CENTER;
          else invoke(0,sum,a_mem[index],SUM_SAVE);
        end
        SUM_SAVE: begin
          sum<=result;
          if(index==length-1) begin index<=0; state<=MEAN_MULT; end
          else begin index<=index+1; invoke(0,result,a_mem[index+1],SUM_SAVE); end
        end
        MEAN_MULT: invoke(1,sum,inv_length,MEAN_SAVE);
        MEAN_SAVE: begin mean<=result; sum<=0; state<=CENTER; end
        CENTER: invoke(0,a_mem[index],{~mean[31],mean[30:0]},CENTER_SAVE);
        CENTER_SAVE: begin work_mem[index]<=result; state<=SQUARE; end
        SQUARE: invoke(1,result,result,VAR_ADD);
        VAR_ADD: invoke(0,sum,result,VAR_SAVE);
        VAR_SAVE: begin
          sum<=result;
          if(index==length-1) begin index<=0; state<=VAR_MEAN; end
          else begin index<=index+1; state<=CENTER; end
        end
        VAR_MEAN: invoke(1,sum,inv_length,EPS_ADD);
        EPS_ADD: invoke(0,result,epsilon,INV_SQRT);
        INV_SQRT: invoke(4,result,0,FACTOR_SAVE);
        FACTOR_SAVE: begin factor<=result; state<=MAP; end
        EXP_CENTER: invoke(0,a_mem[index],{~maximum[31],maximum[30:0]},EXP_START);
        EXP_START: invoke(2,result,0,EXP_SAVE);
        EXP_SAVE: begin work_mem[index]<=result; state<=EXP_SUM; end
        EXP_SUM: invoke(0,sum,result,EXP_SUM_SAVE);
        EXP_SUM_SAVE: begin
          sum<=result;
          if(index==length-1) begin index<=0; state<=INV_SUM; end
          else begin index<=index+1; state<=EXP_CENTER; end
        end
        INV_SUM: invoke(3,sum,0,FACTOR_SAVE);
        MAP: begin
          if(op<8) invoke(op,a_mem[index],b_mem[index],EMIT);
          else if(op==10) invoke(1,work_mem[index],factor,EMIT);
          else invoke(1,work_mem[index],factor,NORM_GAMMA);
        end
        NORM_GAMMA: begin
          if(op==8) invoke(1,result,b_mem[index],EMIT);
          else invoke(1,result,b_mem[index],NORM_BETA);
        end
        NORM_BETA: invoke(0,result,c_mem[index],EMIT);
        EMIT: if(output_ready) begin
          if(index==length-1) begin done<=1; state<=IDLE; end
          else begin index<=index+1; state<=MAP; end
        end
        FAULTED: state<=FAULTED;
        default: state<=FAULTED;
      endcase
    end
  end
endmodule
