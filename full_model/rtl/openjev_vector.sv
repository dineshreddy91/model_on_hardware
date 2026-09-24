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
    MAP,NORM_GAMMA,NORM_BETA,EMIT,FAULTED,LOAD_COMMIT,
    MEMORY_READ,MEMORY_LATCH,SUM_ACC,CENTER_CALC,EXP_CALC,MAP_CALC,GAMMA_CALC,BETA_CALC} state_t;
  state_t state,return_state,memory_return;
  localparam integer ADDR_WIDTH=$clog2(MAX_LENGTH);
  logic [ADDR_WIDTH-1:0] memory_address;
  logic [31:0] load_a,load_b,load_c;
  logic [31:0] a_raw,b_raw,c_raw,work_raw,a_word,b_word,c_word,work_word;
  (* ram_style="block" *) logic [31:0] a_mem[0:MAX_LENGTH-1],b_mem[0:MAX_LENGTH-1],c_mem[0:MAX_LENGTH-1];
  (* ram_style="block" *) logic [31:0] work_mem[0:MAX_LENGTH-1];
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

  task automatic fetch_memory(input logic [31:0] address,input state_t next_state);
    begin memory_address<=address[ADDR_WIDTH-1:0];memory_return<=next_state;state<=MEMORY_READ;end
  endtask
  always_ff @(posedge clk) begin
    if(rst_n && state==LOAD_COMMIT) begin
      a_mem[index[ADDR_WIDTH-1:0]]<=load_a;
      b_mem[index[ADDR_WIDTH-1:0]]<=load_b;
      c_mem[index[ADDR_WIDTH-1:0]]<=load_c;
    end
    if(rst_n && (state==CENTER_SAVE||state==EXP_SAVE)) work_mem[index[ADDR_WIDTH-1:0]]<=result;
    a_raw<=a_mem[memory_address];a_word<=a_raw;
    b_raw<=b_mem[memory_address];b_word<=b_raw;
    c_raw<=c_mem[memory_address];c_word<=c_raw;
    work_raw<=work_mem[memory_address];work_word<=work_raw;
  end
  always_ff @(posedge clk) begin
    if(!rst_n) begin
      memory_address<=0;memory_return<=IDLE;load_a<=0;load_b<=0;load_c<=0;
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
            load_a<=input_a;load_b<=input_b;load_c<=input_c;state<=LOAD_COMMIT;
            if(fp_less(maximum,input_a)) maximum<=input_a;

          end
        end
        LOAD_COMMIT: begin
          if(index==length-1) begin index<=0;state<=START;end
          else begin index<=index+1;state<=LOAD;end
        end
        MEMORY_READ: state<=MEMORY_LATCH;
        MEMORY_LATCH: state<=memory_return;
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
          else fetch_memory(index,SUM_ACC);
        end
        SUM_ACC: invoke(0,sum,a_word,SUM_SAVE);
        SUM_SAVE: begin
          sum<=result;
          if(index==length-1) begin index<=0; state<=MEAN_MULT; end
          else begin index<=index+1; fetch_memory(index+1,SUM_ACC); end
        end
        MEAN_MULT: invoke(1,sum,inv_length,MEAN_SAVE);
        MEAN_SAVE: begin mean<=result; sum<=0; state<=CENTER; end
        CENTER: fetch_memory(index,CENTER_CALC);
        CENTER_CALC: invoke(0,a_word,{~mean[31],mean[30:0]},CENTER_SAVE);
        CENTER_SAVE: begin state<=SQUARE; end
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
        EXP_CENTER: fetch_memory(index,EXP_CALC);
        EXP_CALC: invoke(0,a_word,{~maximum[31],maximum[30:0]},EXP_START);
        EXP_START: invoke(2,result,0,EXP_SAVE);
        EXP_SAVE: begin state<=EXP_SUM; end
        EXP_SUM: invoke(0,sum,result,EXP_SUM_SAVE);
        EXP_SUM_SAVE: begin
          sum<=result;
          if(index==length-1) begin index<=0; state<=INV_SUM; end
          else begin index<=index+1; state<=EXP_CENTER; end
        end
        INV_SUM: invoke(3,sum,0,FACTOR_SAVE);
        MAP: fetch_memory(index,MAP_CALC);
        MAP_CALC: begin
          if(op<8) invoke(op,a_word,b_word,EMIT);
          else if(op==10) invoke(1,work_word,factor,EMIT);
          else invoke(1,work_word,factor,NORM_GAMMA);
        end
        NORM_GAMMA: fetch_memory(index,GAMMA_CALC);
        GAMMA_CALC: begin
          if(op==8) invoke(1,result,b_word,EMIT);
          else invoke(1,result,b_word,NORM_BETA);
        end
        NORM_BETA: fetch_memory(index,BETA_CALC);
        BETA_CALC: invoke(0,result,c_word,EMIT);
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
