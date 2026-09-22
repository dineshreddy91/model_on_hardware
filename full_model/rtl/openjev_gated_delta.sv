`timescale 1ns/1ps
// One recurrent head. Read tensors: Q=0,K=1,V=2,initial state=3,g=4,beta=5.
// g is log decay <=0, beta is in [0,1]. Q/K L2 normalization is done here.
// Outputs are token values then the final [key_dim,value_dim] state (state=1).
module openjev_gated_delta #(
  parameter integer MAX_KEY_DIM=128,MAX_VALUE_DIM=128,MAX_TOKENS=4096,
  parameter logic [63:0] WATCHDOG_CYCLES=64'd20000000000
)(
  input logic clk,rst_n,command_valid,
  output logic command_ready,command_error,
  input logic [31:0] token_count,key_dim,value_dim,
  input logic initial_state_from_memory,reuse_state,
  output logic read_valid,
  input logic read_ready,
  output logic [2:0] read_tensor,
  output logic [31:0] read_index,
  input logic response_valid,
  output logic response_ready,
  input logic [31:0] response_data,
  input logic response_error,
  output logic output_valid,
  input logic output_ready,
  output logic output_state,
  output logic [31:0] output_index,output_data,
  output logic output_last,
  output logic done,fault,
  output logic [3:0] fault_code
);
  import openjev_fp32_pkg::*;
  typedef enum logic [5:0] {IDLE,READ_ISSUE,READ_WAIT,ALU_ISSUE,ALU_WAIT,
    INIT,INIT_SAVE,SCALE_SAVE,Q_FETCH,Q_SQUARE,Q_SUM,Q_SUM_SAVE,
    K_FETCH,K_SQUARE,K_SUM,K_SUM_SAVE,Q_EPS,Q_INV,Q_SCALE,Q_FACTOR,
    K_EPS,K_INV,K_FACTOR,NORM_Q,NORM_Q_SAVE,NORM_K,NORM_K_SAVE,
    G_FETCH,G_EXP,G_SAVE,BETA_FETCH,BETA_SAVE,V_FETCH,V_SAVE,
    DECAY,DECAY_SAVE,MEM_MUL,MEM_ADD,MEM_SUM,DELTA_SUB,DELTA_MUL,
    DELTA_SAVE,UPDATE_MUL,UPDATE_ADD,UPDATE_SAVE,OUT_MUL,OUT_ADD,
    OUT_SUM,EMIT_VALUE,EXPORT,FAULTED} state_t;
  state_t state,read_return,alu_return;
  logic [31:0] state_mem[0:MAX_KEY_DIM*MAX_VALUE_DIM-1];
  logic [31:0] qmem[0:MAX_KEY_DIM-1],kmem[0:MAX_KEY_DIM-1];
  logic [31:0] nt,kd,vd,ti,ki,vj,si,stored_kd,stored_vd,state_count;
  logic [63:0] cycles;
  logic state_valid,load_state;
  logic [31:0] loaded,result,qsum,ksum,qfactor,kfactor,query_scale,decay,beta,value,delta,sum;
  logic [3:0] alu_opcode;
  logic [31:0] alu_a,alu_b,alu_output;
  logic alu_ready,alu_valid,alu_error;
  assign command_ready=rst_n && state==IDLE;
  assign read_valid=rst_n && state==READ_ISSUE;
  assign response_ready=rst_n && state==READ_WAIT;
  assign output_valid=rst_n && (state==EMIT_VALUE || state==EXPORT);
  assign output_state=state==EXPORT;
  assign output_index=state==EXPORT ? si : ti*vd+vj;
  assign output_data=state==EXPORT ? state_mem[si] : sum;
  assign output_last=state==EXPORT && si==state_count-1;
  assign fault=state==FAULTED;
  openjev_scalar arithmetic(.clk(clk),.rst_n(rst_n),.input_valid(state==ALU_ISSUE),
    .input_ready(alu_ready),.opcode(alu_opcode),.input_a(alu_a),.input_b(alu_b),
    .output_valid(alu_valid),.output_ready(state==ALU_WAIT),.output_data(alu_output),.output_error(alu_error));
  task automatic fetch(input logic [2:0] tensor_id,input logic [31:0] index,input state_t next_state);
    begin read_tensor<=tensor_id; read_index<=index; read_return<=next_state; state<=READ_ISSUE; end
  endtask
  task automatic calculate(input logic [3:0] op,input logic [31:0] a,b,input state_t next_state);
    begin alu_opcode<=op; alu_a<=a; alu_b<=b; alu_return<=next_state; state<=ALU_ISSUE; end
  endtask
  always_ff @(posedge clk) begin
    if(!rst_n) begin
      state<=IDLE; read_return<=IDLE; alu_return<=IDLE; command_error<=0; done<=0; fault_code<=0;
      nt<=0; kd<=0; vd<=0; ti<=0; ki<=0; vj<=0; si<=0; cycles<=0; stored_kd<=0; stored_vd<=0; state_count<=0;
      state_valid<=0; load_state<=0; loaded<=0; result<=0; qsum<=0; ksum<=0;
      qfactor<=0; kfactor<=0; query_scale<=0; decay<=0; beta<=0; value<=0; delta<=0; sum<=0;
      read_tensor<=0; read_index<=0; alu_opcode<=0; alu_a<=0; alu_b<=0;
    end else begin
      command_error<=0; done<=0;
      case(state)
        IDLE: if(command_valid) begin
          if(token_count==0 || token_count>MAX_TOKENS || key_dim==0 || key_dim>MAX_KEY_DIM ||
             value_dim==0 || value_dim>MAX_VALUE_DIM || WATCHDOG_CYCLES==0 ||
             (reuse_state && (initial_state_from_memory || !state_valid || key_dim!=stored_kd || value_dim!=stored_vd)))
            command_error<=1;
          else begin
            state_count<=key_dim*value_dim;
            nt<=token_count; kd<=key_dim; vd<=value_dim; ti<=0; ki<=0; vj<=0; si<=0; cycles<=0;
            qsum<=0; ksum<=0; state_valid<=0; stored_kd<=key_dim; stored_vd<=value_dim;
            load_state<=initial_state_from_memory;
            if(reuse_state) calculate(4,fp_from_u13(key_dim[12:0]),0,SCALE_SAVE);
            else state<=INIT;
          end
        end
        READ_ISSUE: if(read_ready) state<=READ_WAIT;
        READ_WAIT: if(response_valid) begin
          if(response_error) begin fault_code<=1; state<=FAULTED; end
          else if(!finite(response_data)) begin fault_code<=2; state<=FAULTED; end
          else begin loaded<=response_data; state<=read_return; end
        end
        ALU_ISSUE: if(alu_ready) state<=ALU_WAIT;
        ALU_WAIT: if(alu_valid) begin
          if(alu_error) begin fault_code<=2; state<=FAULTED; end
          else begin result<=alu_output; state<=alu_return; end
        end
        INIT: begin
          if(load_state) fetch(3,si,INIT_SAVE);
          else begin loaded<=0; state<=INIT_SAVE; end
        end
        INIT_SAVE: begin
          state_mem[si]<=loaded;
          if(si==state_count-1) begin si<=0; calculate(4,fp_from_u13(kd[12:0]),0,SCALE_SAVE); end
          else begin si<=si+1; state<=INIT; end
        end
        SCALE_SAVE: begin query_scale<=result; state<=Q_FETCH; end
        Q_FETCH: fetch(0,ti*kd+ki,Q_SQUARE);
        Q_SQUARE: begin qmem[ki]<=loaded; calculate(1,loaded,loaded,Q_SUM); end
        Q_SUM: calculate(0,qsum,result,Q_SUM_SAVE);
        Q_SUM_SAVE: begin
          qsum<=result;
          if(ki==kd-1) begin ki<=0; state<=K_FETCH; end
          else begin ki<=ki+1; state<=Q_FETCH; end
        end
        K_FETCH: fetch(1,ti*kd+ki,K_SQUARE);
        K_SQUARE: begin kmem[ki]<=loaded; calculate(1,loaded,loaded,K_SUM); end
        K_SUM: calculate(0,ksum,result,K_SUM_SAVE);
        K_SUM_SAVE: begin
          ksum<=result;
          if(ki==kd-1) begin ki<=0; state<=Q_EPS; end
          else begin ki<=ki+1; state<=K_FETCH; end
        end
        Q_EPS: calculate(0,qsum,32'h358637bd,Q_INV);
        Q_INV: calculate(4,result,0,Q_SCALE);
        Q_SCALE: calculate(1,result,query_scale,Q_FACTOR);
        Q_FACTOR: begin qfactor<=result; state<=K_EPS; end
        K_EPS: calculate(0,ksum,32'h358637bd,K_INV);
        K_INV: calculate(4,result,0,K_FACTOR);
        K_FACTOR: begin kfactor<=result; state<=NORM_Q; end
        NORM_Q: calculate(1,qmem[ki],qfactor,NORM_Q_SAVE);
        NORM_Q_SAVE: begin qmem[ki]<=result; state<=NORM_K; end
        NORM_K: calculate(1,kmem[ki],kfactor,NORM_K_SAVE);
        NORM_K_SAVE: begin
          kmem[ki]<=result;
          if(ki==kd-1) begin ki<=0; state<=G_FETCH; end
          else begin ki<=ki+1; state<=NORM_Q; end
        end
        G_FETCH: fetch(4,ti,G_EXP);
        G_EXP: begin
          if(!loaded[31] && loaded[30:0]!=0) begin fault_code<=3; state<=FAULTED; end
          else calculate(2,loaded,0,G_SAVE);
        end
        G_SAVE: begin decay<=result; state<=BETA_FETCH; end
        BETA_FETCH: fetch(5,ti,BETA_SAVE);
        BETA_SAVE: begin
          if((loaded[31] && loaded[30:0]!=0) || fp_less(32'h3f800000,loaded)) begin fault_code<=3; state<=FAULTED; end
          else begin beta<=loaded; vj<=0; state<=V_FETCH; end
        end
        V_FETCH: fetch(2,ti*vd+vj,V_SAVE);
        V_SAVE: begin value<=loaded; ki<=0; sum<=0; state<=DECAY; end
        DECAY: calculate(1,state_mem[ki*vd+vj],decay,DECAY_SAVE);
        DECAY_SAVE: begin state_mem[ki*vd+vj]<=result; state<=MEM_MUL; end
        MEM_MUL: calculate(1,result,kmem[ki],MEM_ADD);
        MEM_ADD: calculate(0,sum,result,MEM_SUM);
        MEM_SUM: begin
          sum<=result;
          if(ki==kd-1) state<=DELTA_SUB;
          else begin ki<=ki+1; state<=DECAY; end
        end
        DELTA_SUB: calculate(0,value,{~sum[31],sum[30:0]},DELTA_MUL);
        DELTA_MUL: calculate(1,result,beta,DELTA_SAVE);
        DELTA_SAVE: begin delta<=result; ki<=0; sum<=0; state<=UPDATE_MUL; end
        UPDATE_MUL: calculate(1,kmem[ki],delta,UPDATE_ADD);
        UPDATE_ADD: calculate(0,state_mem[ki*vd+vj],result,UPDATE_SAVE);
        UPDATE_SAVE: begin state_mem[ki*vd+vj]<=result; state<=OUT_MUL; end
        OUT_MUL: calculate(1,result,qmem[ki],OUT_ADD);
        OUT_ADD: calculate(0,sum,result,OUT_SUM);
        OUT_SUM: begin
          sum<=result;
          if(ki==kd-1) state<=EMIT_VALUE;
          else begin ki<=ki+1; state<=UPDATE_MUL; end
        end
        EMIT_VALUE: if(output_ready) begin
          if(vj!=vd-1) begin vj<=vj+1; state<=V_FETCH; end
          else if(ti!=nt-1) begin ti<=ti+1; ki<=0; qsum<=0; ksum<=0; state<=Q_FETCH; end
          else begin si<=0; state<=EXPORT; end
        end
        EXPORT: if(output_ready) begin
          if(si==state_count-1) begin state_valid<=1; done<=1; state<=IDLE; end
          else si<=si+1;
        end
        FAULTED: state<=FAULTED;
        default: begin fault_code<=6; state<=FAULTED; end
      endcase
      if(state!=IDLE && state!=FAULTED) begin
        if(cycles>=WATCHDOG_CYCLES-1) begin fault_code<=5; state<=FAULTED; done<=0; end
        else cycles<=cycles+1;
      end
    end
  end
endmodule
