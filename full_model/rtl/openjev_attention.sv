`timescale 1ns/1ps
// One attention head per command. External read interface supplies FP32 Q/K/V
// by logical element index; tensor 3 supplies integer 0/1 key-valid masks.
// A memory adapter (not host arithmetic) maps these indices to HBM tensor views.
module openjev_attention #(
  parameter integer MAX_KEYS=4096,
  parameter integer MAX_DIM=256,
  parameter logic [63:0] WATCHDOG_CYCLES=64'd20000000000
)(
  input logic clk,rst_n,command_valid,
  output logic command_ready,command_error,
  input logic [31:0] query_count,key_count,head_dim,query_offset,
  input logic causal,use_key_mask,
  output logic read_valid,
  input logic read_ready,
  output logic [1:0] read_tensor,
  output logic [31:0] read_index,
  input logic response_valid,
  output logic response_ready,
  input logic [31:0] response_data,
  input logic response_error,
  output logic output_valid,
  input logic output_ready,
  output logic [31:0] output_index,output_data,
  output logic output_last,
  output logic done,fault,
  output logic [3:0] fault_code
);
  import openjev_fp32_pkg::*;
  typedef enum logic [5:0] {IDLE,READ_ISSUE,READ_WAIT,ALU_ISSUE,ALU_WAIT,
    SCALE_SAVE,Q_FETCH,Q_SAVE,KEY_START,MASK_SAVE,KEY_DECIDE,K_FETCH,
    DOT_MUL,DOT_ADD,DOT_SAVE,SCORE_SCALE,SCORE_SAVE,KEY_NEXT,
    EXP_START,EXP_ARG,EXP_EVAL,EXP_SAVE,SUM_SAVE,INVERSE,
    INVERSE_SAVE,PROB_START,PROB_SAVE,VALUE_START,VALUE_FETCH,
    VALUE_MUL,VALUE_ADD,VALUE_SAVE,VALUE_NEXT,EMIT,FAULTED,
    SCORE_READ,SCORE_LATCH,EXP_CHECK,PROB_CHECK,VALUE_CHECK} state_t;
  state_t state,read_return,alu_return,score_return;
  localparam integer SCORE_ADDR_WIDTH=$clog2(MAX_KEYS);
  logic [SCORE_ADDR_WIDTH-1:0] score_address;
  logic [31:0] score_raw,score_word;
  logic enabled_raw,enabled_word;
  logic [63:0] cycles;
  logic [31:0] qmem[0:MAX_DIM-1];
  (* ram_style="block" *) logic [31:0] scores[0:MAX_KEYS-1];
  logic enabled[0:MAX_KEYS-1];
  logic [31:0] nq,nk,dim,qoff,qi,kj,di,vd;
  logic [31:0] query_base,key_base;
  logic is_causal,masked,key_enabled,any_key;
  logic [31:0] loaded,result,sum,maximum,scale,inverse;
  logic [3:0] alu_opcode;
  logic [31:0] alu_a,alu_b,alu_output;
  logic alu_ready,alu_valid,alu_error;
  assign command_ready=rst_n && state==IDLE;
  assign read_valid=rst_n && state==READ_ISSUE;
  assign response_ready=rst_n && state==READ_WAIT;
  assign output_valid=rst_n && state==EMIT;
  assign output_data=sum;
  assign output_index=query_base+vd;
  assign output_last=qi==nq-1 && vd==dim-1;
  assign fault=state==FAULTED;
  openjev_scalar arithmetic(.clk(clk),.rst_n(rst_n),.input_valid(state==ALU_ISSUE),
    .input_ready(alu_ready),.opcode(alu_opcode),.input_a(alu_a),.input_b(alu_b),
    .output_valid(alu_valid),.output_ready(state==ALU_WAIT),.output_data(alu_output),.output_error(alu_error));
  task automatic fetch(input logic [1:0] tensor_id,input logic [31:0] index,input state_t next_state);
    begin read_tensor<=tensor_id; read_index<=index; read_return<=next_state; state<=READ_ISSUE; end
  endtask
  task automatic calculate(input logic [3:0] op,input logic [31:0] a,b,input state_t next_state);
    begin alu_opcode<=op; alu_a<=a; alu_b<=b; alu_return<=next_state; state<=ALU_ISSUE; end
  endtask
  always_ff @(posedge clk) begin
    score_raw<=scores[score_address];score_word<=score_raw;
    enabled_raw<=enabled[score_address];enabled_word<=enabled_raw;
  end
  task automatic fetch_score(input state_t next_state);
    begin score_address<=kj[SCORE_ADDR_WIDTH-1:0];score_return<=next_state;state<=SCORE_READ;end
  endtask
  always_ff @(posedge clk) begin
    if(!rst_n) begin
      score_address<=0;score_return<=IDLE;query_base<=0;key_base<=0;
      state<=IDLE; read_return<=IDLE; alu_return<=IDLE; command_error<=0; done<=0; fault_code<=0;
      nq<=0; nk<=0; dim<=0; qoff<=0; qi<=0; kj<=0; di<=0; vd<=0; cycles<=0;
      is_causal<=0; masked<=0; key_enabled<=0; any_key<=0;
      loaded<=0; result<=0; sum<=0; maximum<=0; scale<=0; inverse<=0;
      read_tensor<=0; read_index<=0; alu_opcode<=0; alu_a<=0; alu_b<=0;
    end else begin
      command_error<=0; done<=0;
      case(state)
        IDLE: if(command_valid) begin
          if(query_count==0 || query_count>MAX_KEYS || key_count==0 || key_count>MAX_KEYS ||
             head_dim==0 || head_dim>MAX_DIM || WATCHDOG_CYCLES==0 ||
             (causal && ({1'b0,query_offset}+{1'b0,query_count}>{1'b0,key_count}))) command_error<=1;
          else begin
            query_base<=0;key_base<=0;nq<=query_count; nk<=key_count; dim<=head_dim; qoff<=query_offset;
            is_causal<=causal; masked<=use_key_mask; qi<=0; kj<=0; di<=0; vd<=0; cycles<=0;
            any_key<=0; maximum<=32'hff7fffff; sum<=0;
            calculate(4,fp_from_u13(head_dim[12:0]),0,SCALE_SAVE);
          end
        end
        READ_ISSUE: if(read_ready) state<=READ_WAIT;
        READ_WAIT: if(response_valid) begin
          if(response_error) begin fault_code<=1; state<=FAULTED; end
          else if(read_tensor!=3 && !finite(response_data)) begin fault_code<=2; state<=FAULTED; end
          else begin loaded<=response_data; state<=read_return; end
        end
        ALU_ISSUE: if(alu_ready) state<=ALU_WAIT;
        ALU_WAIT: if(alu_valid) begin
          if(alu_error) begin fault_code<=2; state<=FAULTED; end
          else begin result<=alu_output; state<=alu_return; end
        end
        SCORE_READ: state<=SCORE_LATCH;
        SCORE_LATCH: state<=score_return;
        SCALE_SAVE: begin scale<=result; state<=Q_FETCH; end
        Q_FETCH: fetch(0,query_base+di,Q_SAVE);
        Q_SAVE: begin
          qmem[di]<=loaded;
          if(di==dim-1) begin di<=0; kj<=0; key_base<=0; any_key<=0; maximum<=32'hff7fffff; state<=KEY_START; end
          else begin di<=di+1; state<=Q_FETCH; end
        end
        KEY_START: begin
          key_enabled<=!is_causal || kj<=qoff+qi;
          if(masked) fetch(3,kj,MASK_SAVE);
          else state<=KEY_DECIDE;
        end
        MASK_SAVE: begin
          if(loaded>1) begin fault_code<=3; state<=FAULTED; end
          else begin key_enabled<=key_enabled && loaded[0]; state<=KEY_DECIDE; end
        end
        KEY_DECIDE: begin
          enabled[kj[SCORE_ADDR_WIDTH-1:0]]<=key_enabled;
          if(key_enabled) begin sum<=0; di<=0; any_key<=1; state<=K_FETCH; end
          else begin scores[kj[SCORE_ADDR_WIDTH-1:0]]<=0; state<=KEY_NEXT; end
        end
        K_FETCH: fetch(1,key_base+di,DOT_MUL);
        DOT_MUL: calculate(1,qmem[di],loaded,DOT_ADD);
        DOT_ADD: calculate(0,sum,result,DOT_SAVE);
        DOT_SAVE: begin
          sum<=result;
          if(di==dim-1) state<=SCORE_SCALE;
          else begin di<=di+1; state<=K_FETCH; end
        end
        SCORE_SCALE: calculate(1,sum,scale,SCORE_SAVE);
        SCORE_SAVE: begin
          scores[kj[SCORE_ADDR_WIDTH-1:0]]<=result;
          if(fp_less(maximum,result)) maximum<=result;
          state<=KEY_NEXT;
        end
        KEY_NEXT: begin
          if(kj==nk-1) begin
            if(!any_key) begin fault_code<=4; state<=FAULTED; end
            else begin kj<=0; sum<=0; state<=EXP_START; end
          end else begin kj<=kj+1;key_base<=key_base+dim; state<=KEY_START; end
        end
        EXP_START: fetch_score(EXP_CHECK);
        EXP_CHECK: begin
          if(enabled_word) state<=EXP_ARG;
          else if(kj==nk-1) state<=INVERSE;
          else begin kj<=kj+1;state<=EXP_START;end
        end
        EXP_ARG: calculate(0,score_word,{~maximum[31],maximum[30:0]},EXP_EVAL);
        EXP_EVAL: calculate(2,result,0,EXP_SAVE);
        EXP_SAVE: begin scores[kj[SCORE_ADDR_WIDTH-1:0]]<=result; calculate(0,sum,result,SUM_SAVE); end
        SUM_SAVE: begin
          sum<=result;
          if(kj==nk-1) state<=INVERSE;
          else begin kj<=kj+1; state<=EXP_START; end
        end
        INVERSE: calculate(3,sum,0,INVERSE_SAVE);
        INVERSE_SAVE: begin inverse<=result; kj<=0; state<=PROB_START; end
        PROB_START: fetch_score(PROB_CHECK);
        PROB_CHECK: begin
          if(enabled_word) calculate(1,score_word,inverse,PROB_SAVE);
          else if(kj==nk-1) begin vd<=0; state<=VALUE_START; end
          else begin kj<=kj+1;state<=PROB_START;end
        end
        PROB_SAVE: begin
          scores[kj[SCORE_ADDR_WIDTH-1:0]]<=result;
          if(kj==nk-1) begin vd<=0; state<=VALUE_START; end
          else begin kj<=kj+1; state<=PROB_START; end
        end
        VALUE_START: begin key_base<=0;kj<=0; sum<=0; state<=VALUE_FETCH; end
        VALUE_FETCH: fetch_score(VALUE_CHECK);
        VALUE_CHECK: begin
          if(enabled_word) fetch(2,key_base+vd,VALUE_MUL);
          else state<=VALUE_NEXT;
        end
        VALUE_MUL: calculate(1,score_word,loaded,VALUE_ADD);
        VALUE_ADD: calculate(0,sum,result,VALUE_SAVE);
        VALUE_SAVE: begin sum<=result; state<=VALUE_NEXT; end
        VALUE_NEXT: begin
          if(kj==nk-1) state<=EMIT;
          else begin kj<=kj+1;key_base<=key_base+dim; state<=VALUE_FETCH; end
        end
        EMIT: if(output_ready) begin
          if(vd!=dim-1) begin vd<=vd+1; state<=VALUE_START; end
          else if(qi!=nq-1) begin qi<=qi+1;query_base<=query_base+dim; di<=0; state<=Q_FETCH; end
          else begin done<=1; state<=IDLE; end
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
