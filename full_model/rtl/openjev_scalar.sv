`timescale 1ns/1ps
// Serialized scalar arithmetic. Opcodes: ADD,MUL,EXP,RECIP,RSQRT,SIGMOID,SILU,GELU_TANH.
// One shared add/multiply datapath; no host calculation or lookup service.
module openjev_scalar (
  input logic clk,rst_n,input_valid,
  output logic input_ready,
  input logic [3:0] opcode,
  input logic [31:0] input_a,input_b,
  output logic output_valid,
  input logic output_ready,
  output logic [31:0] output_data,
  output logic output_error
);
  import openjev_fp32_pkg::*;
  typedef enum logic [5:0] {IDLE,BASIC,EXP_BEGIN,EXP_K,EXP_INTEGER,EXP_HI,EXP_SUB,
    EXP_LO,EXP_REMAINDER,EXP_MUL,EXP_ADD,EXP_END,REC_BEGIN,REC_SEED,
    REC_SUB,REC_MUL,REC_CORRECT,REC_UPDATE,REC_END,SQ_BEGIN,SQ_YY,
    SQ_MY,SQ_HALF,SQ_SUB,SQ_UPDATE,SQ_END,SIG_BEGIN,SIG_DENOM,
    SIG_END,SIG_PRODUCT,GELU_CUBE,GELU_COEFF,GELU_ADD,GELU_SCALE,
    FINISH} state_t;
  state_t state;
  logic [3:0] op;
  logic [31:0] original,argument,basic_b,t,y,m,remainder_value,polynomial,exponential;
  logic [31:0] alu_a,alu_b,alu_value,alu_a_q,alu_b_q;
  logic alu_multiply_q,uses_alu;
  logic [1:0] alu_phase;
  logic alu_multiply,sign_value,alu_scale,alu_scale_q;
  integer alu_scale_power,alu_scale_power_q;
  wire alu_input_ready,alu_output_valid;
  wire [31:0] alu_result;
  openjev_fp32_alu datapath(
    .clk(clk),.rst_n(rst_n),.input_valid(uses_alu && alu_phase==1),
    .input_ready(alu_input_ready),.multiply(alu_multiply_q),
    .scale_mode(alu_scale_q),.scale_power(alu_scale_power_q),
    .input_a(alu_a_q),.input_b(alu_b_q),
    .output_valid(alu_output_valid),.output_ready(alu_phase==3),.output_data(alu_result));
  integer exponent_value,k,iteration,coefficient,normal_exponent,leading;
  logic [31:0] integer_fixed;
  logic integer_negative;
  wire [8:0] integer_rounded={1'b0,integer_fixed[31:24]} +
    ((integer_fixed[23:0]>24'h800000) || (integer_fixed[23:0]==24'h800000 && integer_fixed[24]));
  logic [23:0] significand,normalized_significand;
  logic [31:0] normalized;

  assign input_ready = rst_n && state==IDLE && !output_valid;
  always_comb begin
    significand={(argument[30:23]!=0),argument[22:0]};
    leading=0;
    for(integer i=0;i<24;i=i+1) if(significand[i]) leading=i;
    normal_exponent=(argument[30:23]==0 ? -126 : int'(argument[30:23])-127)+leading-23;
    // Normalizing a finite binary32 significand is exact: no second
    // round/pack datapath is needed to force the exponent to 127.
    normalized_significand=significand << (23-leading);
    normalized={1'b0,8'd127,normalized_significand[22:0]};
    alu_a=0; alu_b=0; alu_multiply=0;alu_scale=0;alu_scale_power=0;
    case(state)
      BASIC: begin alu_a=argument; alu_b=basic_b; alu_multiply=op==1 || op==7; end
      EXP_K: begin alu_a=argument; alu_b=32'h3fb8aa3b; alu_multiply=1; end
      EXP_HI: begin alu_a=fp_from_i10(k[9:0]); alu_b=32'h3f317200; alu_multiply=1; end
      EXP_SUB: begin alu_a=argument; alu_b={~t[31],t[30:0]}; end
      EXP_LO: begin alu_a=fp_from_i10(k[9:0]); alu_b=32'h35bfbe8e; alu_multiply=1; end
      EXP_REMAINDER: begin alu_a=remainder_value; alu_b={~t[31],t[30:0]}; end
      EXP_MUL: begin alu_a=polynomial; alu_b=remainder_value; alu_multiply=1; end
      EXP_ADD: begin
        alu_a=t;
        case(coefficient)
          6: alu_b=32'h3ab60b61; // 1/720
          5: alu_b=32'h3c088889;
          4: alu_b=32'h3d2aaaab;
          3: alu_b=32'h3e2aaaab;
          2: alu_b=32'h3f000000;
          default: alu_b=32'h3f800000;
        endcase
      end
      REC_SEED: begin alu_a=m; alu_b=32'h3ff0f0f1; alu_multiply=1; end
      REC_SUB: begin alu_a=32'h4034b4b5; alu_b={~t[31],t[30:0]}; end
      REC_MUL: begin alu_a=m; alu_b=y; alu_multiply=1; end
      REC_CORRECT: begin alu_a=32'h40000000; alu_b={~t[31],t[30:0]}; end
      REC_UPDATE: begin alu_a=y; alu_b=t; alu_multiply=1; end
      SQ_YY: begin alu_a=y; alu_b=y; alu_multiply=1; end
      SQ_MY: begin alu_a=m; alu_b=t; alu_multiply=1; end
      SQ_HALF: begin alu_a=t; alu_b=32'h3f000000; alu_multiply=1; end
      SQ_SUB: begin alu_a=32'h3fc00000; alu_b={~t[31],t[30:0]}; end
      SQ_UPDATE: begin alu_a=y; alu_b=t; alu_multiply=1; end
      SIG_DENOM: begin alu_a=32'h3f800000; alu_b=exponential; end
      SIG_END: begin alu_a=t; alu_b=sign_value ? exponential : 32'h3f800000; alu_multiply=1; end
      SIG_PRODUCT: begin alu_a=original; alu_b=t; alu_multiply=1; end
      GELU_CUBE: begin alu_a=original; alu_b=t; alu_multiply=1; end
      GELU_COEFF: begin alu_a=t; alu_b=32'h3d372713; alu_multiply=1; end
      GELU_ADD: begin alu_a=original; alu_b=t; end
      GELU_SCALE: begin alu_a=t; alu_b=32'h3fcc422a; alu_multiply=1; end
      EXP_END: begin alu_a=polynomial;alu_scale=1;alu_scale_power=k;end
      REC_END: begin alu_a={argument[31],y[30:0]};alu_scale=1;alu_scale_power=-exponent_value;end
      SQ_END: begin alu_a=y;alu_scale=1;alu_scale_power=-exponent_value;end
      default: begin end
    endcase
    uses_alu=0;
    case(state)
      EXP_END,REC_END,SQ_END,BASIC,EXP_K,EXP_HI,EXP_SUB,EXP_LO,EXP_REMAINDER,EXP_MUL,EXP_ADD,
      REC_SEED,REC_SUB,REC_MUL,REC_CORRECT,REC_UPDATE,
      SQ_YY,SQ_MY,SQ_HALF,SQ_SUB,SQ_UPDATE,
      SIG_DENOM,SIG_END,SIG_PRODUCT,GELU_CUBE,GELU_COEFF,GELU_ADD,GELU_SCALE: uses_alu=1;
      default: uses_alu=0;
    endcase
  end

  always_ff @(posedge clk) begin
    if(!rst_n) begin
      alu_phase<=0;alu_scale_q<=0;alu_scale_power_q<=0; alu_a_q<=0; alu_b_q<=0; alu_multiply_q<=0; alu_value<=0;
      state<=IDLE; output_valid<=0; output_data<=0; output_error<=0;
      op<=0; original<=0; argument<=0; basic_b<=0; t<=0; y<=0; m<=0;
      remainder_value<=0; polynomial<=0; exponential<=0; sign_value<=0;
      integer_fixed<=0; integer_negative<=0; exponent_value<=0; k<=0; iteration<=0; coefficient<=0;
    end else begin
      if(output_valid && output_ready) output_valid<=0;
      if(uses_alu && alu_phase==0) begin
        alu_a_q<=alu_a; alu_b_q<=alu_b;alu_scale_q<=alu_scale;alu_scale_power_q<=alu_scale_power; alu_multiply_q<=alu_multiply; alu_phase<=1;
      end else if(uses_alu && alu_phase==1) begin
        if(alu_input_ready) alu_phase<=3;
      end else if(uses_alu && alu_phase==3) begin
        if(alu_output_valid) begin alu_value<=alu_result;alu_phase<=2;end
      end else begin
        alu_phase<=0;
      case(state)
        IDLE: if(input_valid && input_ready) begin
          op<=opcode; original<=input_a; argument<=input_a; basic_b<=input_b;
          output_error<=0;
          if(!finite(input_a) || (opcode<2 && !finite(input_b)) || opcode>7) begin
            t<=0; output_error<=1; state<=FINISH;
          end else case(opcode)
            0,1: state<=BASIC;
            2: state<=EXP_BEGIN;
            3: state<=REC_BEGIN;
            4: state<=SQ_BEGIN;
            5,6: state<=SIG_BEGIN;
            7: begin
              if(input_a[30:0]>32'h41200000) begin
                t<=input_a[31] ? 32'h80000000 : input_a; state<=FINISH;
              end else begin
                // Square uses BASIC's shared multiplier before GELU_CUBE.
                basic_b<=input_a; state<=BASIC;
              end
            end
            default: begin t<=0; output_error<=1; state<=FINISH; end
          endcase
        end
        BASIC: begin t<=alu_value; if(op==7) state<=GELU_CUBE; else state<=FINISH; end
        GELU_CUBE: begin t<=alu_value; state<=GELU_COEFF; end
        GELU_COEFF: begin t<=alu_value; state<=GELU_ADD; end
        GELU_ADD: begin t<=alu_value; state<=GELU_SCALE; end
        GELU_SCALE: begin argument<=alu_value; state<=SIG_BEGIN; end
        SIG_BEGIN: begin
          sign_value<=argument[31]; argument<={1'b1,argument[30:0]}; state<=EXP_BEGIN;
        end
        EXP_BEGIN: begin
          if(!argument[31] && argument>32'h42b00000) begin
            t<=0; output_error<=1; state<=FINISH;
          end else if(argument[31] && argument[30:0]>32'h42d00000) begin
            t<=0; exponential<=0; if(op==2) state<=FINISH; else state<=SIG_DENOM;
          end else state<=EXP_K;
        end
        EXP_K: begin
          // EXP_BEGIN bounds this value to [-151,127]; retain 24 fractional bits.
          integer_fixed<=alu_value[30:23]<126 ? 0 :
            {1'b1,alu_value[22:0],8'b0} >> (8'd134-alu_value[30:23]);
          integer_negative<=alu_value[31];state<=EXP_INTEGER;
        end
        EXP_INTEGER: begin
          k<=integer_negative ? -$signed({23'b0,integer_rounded}) : $signed({23'b0,integer_rounded});
          state<=EXP_HI;
        end
        EXP_HI: begin t<=alu_value; state<=EXP_SUB; end
        EXP_SUB: begin remainder_value<=alu_value; state<=EXP_LO; end
        EXP_LO: begin t<=alu_value; state<=EXP_REMAINDER; end
        EXP_REMAINDER: begin
          remainder_value<=alu_value; polynomial<=32'h39500d01;
          coefficient<=6; state<=EXP_MUL;
        end
        EXP_MUL: begin t<=alu_value; state<=EXP_ADD; end
        EXP_ADD: begin
          polynomial<=alu_value;
          if(coefficient==0) state<=EXP_END;
          else begin coefficient<=coefficient-1; state<=EXP_MUL; end
        end
        EXP_END: begin
          t<=alu_value; exponential<=alu_value;
          if(op==2) state<=FINISH; else state<=SIG_DENOM;
        end
        SIG_DENOM: begin argument<=alu_value; state<=REC_BEGIN; end
        REC_BEGIN: begin
          if(argument[30:0]==0) begin t<=0; output_error<=1; state<=FINISH; end
          else begin
            m<={1'b0,8'd126,normalized[22:0]}; exponent_value<=normal_exponent+1;
            iteration<=0; state<=REC_SEED;
          end
        end
        REC_SEED: begin t<=alu_value; state<=REC_SUB; end
        REC_SUB: begin y<=alu_value; state<=REC_MUL; end
        REC_MUL: begin t<=alu_value; state<=REC_CORRECT; end
        REC_CORRECT: begin t<=alu_value; state<=REC_UPDATE; end
        REC_UPDATE: begin
          y<=alu_value;
          if(iteration==4) state<=REC_END;
          else begin iteration<=iteration+1; state<=REC_MUL; end
        end
        REC_END: begin
          t<=alu_value;
          if(op==3) state<=FINISH; else state<=SIG_END;
        end
        SIG_END: begin t<=alu_value; if(op==5) state<=FINISH; else state<=SIG_PRODUCT; end
        SIG_PRODUCT: begin t<=alu_value; state<=FINISH; end
        SQ_BEGIN: begin
          if(argument[31] || argument[30:0]==0) begin t<=0; output_error<=1; state<=FINISH; end
          else begin
            m<={1'b0,(normal_exponent[0] ? 8'd128 : 8'd127),normalized[22:0]};
            y<=32'h5f375a86-({1'b0,(normal_exponent[0] ? 8'd128 : 8'd127),normalized[22:0]}>>1);
            exponent_value<=(normal_exponent-(normal_exponent & 1))/2;
            iteration<=0; state<=SQ_YY;
          end
        end
        SQ_YY: begin t<=alu_value; state<=SQ_MY; end
        SQ_MY: begin t<=alu_value; state<=SQ_HALF; end
        SQ_HALF: begin t<=alu_value; state<=SQ_SUB; end
        SQ_SUB: begin t<=alu_value; state<=SQ_UPDATE; end
        SQ_UPDATE: begin
          y<=alu_value;
          if(iteration==4) state<=SQ_END;
          else begin iteration<=iteration+1; state<=SQ_YY; end
        end
        SQ_END: begin t<=alu_value; state<=FINISH; end
        FINISH: begin
          output_error<=output_error || !finite(t);
          output_data<=output_error || !finite(t) ? 0 : t;
          output_valid<=1; state<=IDLE;
        end
        default: begin output_error<=1; t<=0; state<=FINISH; end
      endcase
      end
    end
  end
endmodule
