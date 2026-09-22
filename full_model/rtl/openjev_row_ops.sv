`timescale 1ns/1ps
// Tensor-memory adapter for row quantization, affine/vector operations and dequantization.
// The dispatcher validates tensor shapes and supplies rows/width and source dtypes.
// Every output is acknowledged only after the memory response commits the write.
module openjev_row_ops #(
  parameter [63:0] WATCHDOG_CYCLES=64'd20000000000
)(
  input wire clk,rst_n,command_valid,
  output wire command_ready,
  input wire [7:0] opcode,
  input wire [23:0] flags,
  input wire [31:0] row_count,row_width,epsilon,
  input wire [1:0] dtype0,dtype1,dtype2,
  input wire [31:0] source0,source1,source2,destination0,destination1,
  output wire memory_valid,
  input wire memory_ready,
  output reg memory_write,
  output reg [31:0] memory_tensor,memory_index,memory_data,
  input wire memory_response_valid,
  output wire memory_response_ready,
  input wire [31:0] memory_response_data,
  input wire memory_response_error,
  output reg done,
  output wire fault
);
  import openjev_fp32_pkg::*;
  reg [63:0] cycles;
  localparam IDLE=0,LAUNCH=1,READ_A=2,SAVE_A=3,SAVE_B=4,SAVE_C=5,
    FEED=6,OUTPUT_WAIT=7,OUTPUT_ACK=8,NEXT_ROW=9,MEM_ISSUE=10,MEM_WAIT=11,
    SPECIAL_ISSUE=12,SPECIAL_WAIT=13,SCALE_ISSUE=14,SCALE_WAIT=15,
    ALU_ISSUE=16,ALU_WAIT=17,GAMMA_SAVE=18,DQ_SAVE=19,STORE_DIRECT=20,
    DIRECT_NEXT=21,FAILED=22;
  reg [4:0] state,return_state,alu_return;
  reg [7:0] op;
  reg [23:0] flag_q;
  reg [31:0] nr,nc,ri,ci,oi,offset,s0,s1,s2,d0,d1,eps;
  reg [1:0] type0,type1,type2;
  reg [31:0] a,b,c,result_q,alu_a,alu_b;
  reg [3:0] vector_opcode,alu_opcode;
  reg last_output;
  wire vr,ve,vi,vo,vl,vd,vf,qr,qe,qi,qo,qs,ql,qd,qf;
  wire [31:0] vdata,qdata,qindex;
  wire sr,sv,se,dr,dv,de,ar,av,ae;
  wire [31:0] special_data,scaled_data,alu_data;
  wire vector_mode=op==4||op==5||op==6||op==7||op==8||op==9||op==11||op==12||op==15;
  assign command_ready=rst_n&&state==IDLE;
  assign memory_valid=rst_n&&state==MEM_ISSUE;
  assign memory_response_ready=rst_n&&state==MEM_WAIT;
  assign fault=state==FAILED;
  function automatic [31:0] convert(input [31:0] word,input [1:0] dtype);
    begin
      case(dtype)
        0: convert=fp_from_i10({{2{word[7]}},word[7:0]});
        1: convert=fp_from_half(word[15:0]);
        2: convert=word==0 ? 0 : word==1 ? 32'h3f800000 : 32'h7fc00000;
        3: convert=word;
      endcase
    end
  endfunction
  openjev_vector #(.MAX_LENGTH(8192)) vector_unit(
    .clk(clk),.rst_n(rst_n),.command_valid(state==LAUNCH&&vector_mode),.command_ready(vr),.command_error(ve),
    .command_opcode(vector_opcode),.command_length(nc),.command_epsilon(eps),
    .input_valid(state==FEED&&vector_mode),.input_ready(vi),.input_a(a),.input_b(b),.input_c(c),
    .input_last(ci==nc-1),.output_valid(vo),.output_ready(state==OUTPUT_ACK&&vector_mode),
    .output_data(vdata),.output_last(vl),.done(vd),.fault(vf));
  openjev_quantize_row quantizer(
    .clk(clk),.rst_n(rst_n),.command_valid(state==LAUNCH&&op==1),.command_ready(qr),.command_error(qe),
    .length(nc),.input_valid(state==FEED&&op==1),.input_ready(qi),.input_data(a),.input_last(ci==nc-1),
    .output_valid(qo),.output_ready(state==OUTPUT_ACK&&op==1),.output_scale(qs),.output_index(qindex),
    .output_data(qdata),.output_last(ql),.done(qd),.fault(qf));
  openjev_special special_unit(
    .clk(clk),.rst_n(rst_n),.input_valid(state==SPECIAL_ISSUE),.input_ready(sr),
    .opcode(op==10),.input_data(a),.output_valid(sv),.output_ready(state==SPECIAL_WAIT),
    .output_data(special_data),.output_error(se));
  openjev_scaled_int32 dequantizer(
    .clk(clk),.rst_n(rst_n),.input_valid(state==SCALE_ISSUE),.input_ready(dr),.accumulator(a),.scale(c[15:0]),
    .output_valid(dv),.output_ready(state==SCALE_WAIT),.output_data(scaled_data),.output_error(de));
  openjev_scalar scalar(
    .clk(clk),.rst_n(rst_n),.input_valid(state==ALU_ISSUE),.input_ready(ar),.opcode(alu_opcode),
    .input_a(alu_a),.input_b(alu_b),.output_valid(av),.output_ready(state==ALU_WAIT),.output_data(alu_data),.output_error(ae));
  task access;
    input wr;
    input [31:0] tensor_id,element,data;
    input [4:0] next_state;
    begin memory_write<=wr;memory_tensor<=tensor_id;memory_index<=element;memory_data<=data;return_state<=next_state;state<=MEM_ISSUE;end
  endtask
  task calculate;
    input [3:0] operation;
    input [31:0] lhs,rhs;
    input [4:0] next_state;
    begin alu_opcode<=operation;alu_a<=lhs;alu_b<=rhs;alu_return<=next_state;state<=ALU_ISSUE;end
  endtask
  always @(posedge clk) begin
    if(!rst_n) begin
      state<=IDLE;return_state<=IDLE;alu_return<=IDLE;op<=0;flag_q<=0;nr<=0;nc<=0;ri<=0;ci<=0;oi<=0;offset<=0;cycles<=0;
      s0<=0;s1<=0;s2<=0;d0<=0;d1<=0;eps<=0;type0<=0;type1<=0;type2<=0;a<=0;b<=0;c<=0;result_q<=0;
      alu_a<=0;alu_b<=0;vector_opcode<=0;alu_opcode<=0;last_output<=0;
      memory_write<=0;memory_tensor<=0;memory_index<=0;memory_data<=0;done<=0;
    end else begin
      done<=0;
      case(state)
        IDLE: if(command_valid) begin
          if(row_count==0||row_count>262144||row_width==0||row_width>8191||(opcode==1&&row_width>4096)||opcode==0||opcode==2||opcode>15||
             flags>2||(opcode==7&&flags>1)||((opcode!=4&&opcode!=5&&opcode!=7)&&flags!=0)) state<=FAILED;
          else begin
            op<=opcode;flag_q<=flags;nr<=row_count;nc<=row_width;eps<=epsilon;type0<=dtype0;type1<=dtype1;type2<=dtype2;
            s0<=source0;s1<=source1;s2<=source2;d0<=destination0;d1<=destination1;
            ri<=0;ci<=0;oi<=0;offset<=0;cycles<=0;state<=LAUNCH;
            case(opcode)
              4: vector_opcode<=0;5: vector_opcode<=1;6: vector_opcode<=9;7: vector_opcode<=8;
              8: vector_opcode<=6;9: vector_opcode<=7;11: vector_opcode<=5;12: vector_opcode<=2;15: vector_opcode<=10;
              default: vector_opcode<=0;
            endcase
          end
        end
        LAUNCH: if((op==1&&qr)||(vector_mode&&vr)||(!vector_mode&&op!=1)) state<=READ_A;
        READ_A: begin b<=0;c<=0;access(0,s0,offset+ci,0,SAVE_A);end
        SAVE_A: begin
          a<=op==3 ? result_q : convert(result_q,type0);
          if(op==3) access(0,s1,ri,0,SAVE_B);
          else if(op==4||op==5||op==6||op==7)
            access(0,s1,(op==6||op==7||flag_q==1) ? ci : flag_q==2 ? ri : offset+ci,0,SAVE_B);
          else if(op==10||op==13) state<=SPECIAL_ISSUE;
          else if(op==14) begin result_q<=convert(result_q,type0)^32'h80000000;state<=STORE_DIRECT;end
          else state<=FEED;
        end
        SAVE_B: begin
          b<=convert(result_q,type1);
          if(op==3||op==6) access(0,s2,ci,0,SAVE_C);
          else if(op==7&&flag_q==1) calculate(0,convert(result_q,type1),32'h3f800000,GAMMA_SAVE);
          else state<=FEED;
        end
        GAMMA_SAVE: begin b<=result_q;state<=FEED;end
        SAVE_C: begin
          c<=op==3 ? result_q : convert(result_q,type2);
          state<=op==3 ? SCALE_ISSUE : FEED;
        end
        FEED: if((op==1&&qi)||(vector_mode&&vi)) begin
          if(ci==nc-1) begin oi<=0;state<=OUTPUT_WAIT;end
          else begin ci<=ci+1;state<=READ_A;end
        end
        OUTPUT_WAIT: begin
          if(op==1&&qo) begin
            last_output<=ql;access(1,qs ? d1 : d0,qs ? ri : offset+qindex,qdata,OUTPUT_ACK);
          end else if(vector_mode&&vo) begin
            last_output<=vl;access(1,d0,offset+oi,vdata,OUTPUT_ACK);
          end
        end
        OUTPUT_ACK: begin
          if(last_output) state<=NEXT_ROW;
          else begin oi<=oi+1;state<=OUTPUT_WAIT;end
        end
        SPECIAL_ISSUE: if(sr) state<=SPECIAL_WAIT;
        SPECIAL_WAIT: if(sv) begin
          if(se) state<=FAILED;else begin result_q<=special_data;state<=STORE_DIRECT;end
        end
        SCALE_ISSUE: if(dr) state<=SCALE_WAIT;
        SCALE_WAIT: if(dv) begin
          if(de) state<=FAILED;else calculate(1,scaled_data,b,DQ_SAVE);
        end
        DQ_SAVE: state<=STORE_DIRECT;
        STORE_DIRECT: if(!finite(result_q)) state<=FAILED;else access(1,d0,offset+ci,result_q,DIRECT_NEXT);
        DIRECT_NEXT: if(ci==nc-1) state<=NEXT_ROW;else begin ci<=ci+1;state<=READ_A;end
        NEXT_ROW: begin
          if(ri==nr-1) begin done<=1;state<=IDLE;end
          else begin ri<=ri+1;offset<=offset+nc;ci<=0;oi<=0;state<=LAUNCH;end
        end
        MEM_ISSUE: if(memory_ready) state<=MEM_WAIT;
        MEM_WAIT: if(memory_response_valid) begin
          if(memory_response_error) state<=FAILED;
          else begin if(!memory_write) result_q<=memory_response_data;state<=return_state;end
        end
        ALU_ISSUE: if(ar) state<=ALU_WAIT;
        ALU_WAIT: if(av) begin
          if(ae) state<=FAILED;else begin result_q<=alu_data;state<=alu_return;end
        end
        FAILED: state<=FAILED;
        default: state<=FAILED;
      endcase
      if(ve||qe||vf||qf) state<=FAILED;
      if(state!=IDLE&&state!=FAILED) begin
        cycles<=cycles+1;
        if(cycles>=WATCHDOG_CYCLES-1) begin done<=0;state<=FAILED;end
      end
    end
  end
endmodule
