`timescale 1ns/1ps
// Full/partial rotary embeddings on [token,head,dimension] FP32 tensors.
// Cos/sin are [token,rotary_dimension]. Tensor port resolves physical strides.
module openjev_rope #(
  parameter [63:0] WATCHDOG_CYCLES=64'd20000000000
)(
  input wire clk,rst_n,command_valid,
  output wire command_ready,
  input wire [31:0] token_count,head_count,head_dim,rotary_dim,
  input wire [31:0] source,cosine,sine,destination,
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
  localparam IDLE=0,FETCH_X=1,SAVE_X=2,SAVE_COS=3,SAVE_SIN=4,SAVE_PARTNER=5,
    MUL_X=6,MUL_PARTNER=7,ADD=8,STORE=9,NEXT=10,
    MEM_ISSUE=11,MEM_WAIT=12,ALU_ISSUE=13,ALU_WAIT=14,FAILED=15;
  reg [3:0] state,return_state,alu_return;
  reg [31:0] nt,nh,dim,rot,ti,hi,di,index,position_base;
  reg [31:0] src,cs,sn,dst,x,c,s,partner,product,result_q,alu_a,alu_b;
  reg [3:0] alu_op;
  wire ready,valid,error;
  wire [31:0] alu_result;
  assign command_ready=rst_n&&state==IDLE;
  assign memory_valid=rst_n&&state==MEM_ISSUE;
  assign memory_response_ready=rst_n&&state==MEM_WAIT;
  assign fault=state==FAILED;
  openjev_scalar scalar(
    .clk(clk),.rst_n(rst_n),.input_valid(state==ALU_ISSUE),.input_ready(ready),
    .opcode(alu_op),.input_a(alu_a),.input_b(alu_b),
    .output_valid(valid),.output_ready(state==ALU_WAIT),.output_data(alu_result),.output_error(error));
  task access;
    input wr;
    input [31:0] tensor_id,offset,data;
    input [3:0] next_state;
    begin
      memory_write<=wr;memory_tensor<=tensor_id;memory_index<=offset;memory_data<=data;
      return_state<=next_state;state<=MEM_ISSUE;
    end
  endtask
  task calculate;
    input [3:0] op;
    input [31:0] a,b;
    input [3:0] next_state;
    begin alu_op<=op;alu_a<=a;alu_b<=b;alu_return<=next_state;state<=ALU_ISSUE;end
  endtask
  always @(posedge clk) begin
    if(!rst_n) begin
      state<=IDLE;return_state<=IDLE;alu_return<=IDLE;nt<=0;nh<=0;dim<=0;rot<=0;
      ti<=0;hi<=0;di<=0;index<=0;position_base<=0;cycles<=0;
      src<=0;cs<=0;sn<=0;dst<=0;x<=0;c<=0;s<=0;partner<=0;product<=0;
      result_q<=0;alu_a<=0;alu_b<=0;alu_op<=0;memory_write<=0;
      memory_tensor<=0;memory_index<=0;memory_data<=0;done<=0;
    end else begin
      done<=0;
      case(state)
        IDLE: if(command_valid) begin
          if(token_count==0||token_count>4096||head_count==0||head_count>64||
             head_dim==0||head_dim>256||rotary_dim==0||rotary_dim>head_dim||rotary_dim[0]||
             destination==source||destination==cosine||destination==sine)
            state<=FAILED;
          else begin
            nt<=token_count;nh<=head_count;dim<=head_dim;rot<=rotary_dim;
            src<=source;cs<=cosine;sn<=sine;dst<=destination;
            ti<=0;hi<=0;di<=0;index<=0;position_base<=0;cycles<=0;state<=FETCH_X;
          end
        end
        FETCH_X: access(0,src,index,0,SAVE_X);
        SAVE_X: begin
          x<=result_q;
          if(di>=rot) access(1,dst,index,result_q,NEXT);
          else access(0,cs,position_base+di,0,SAVE_COS);
        end
        SAVE_COS: begin c<=result_q;access(0,sn,position_base+di,0,SAVE_SIN);end
        SAVE_SIN: begin s<=result_q;access(0,src,di<rot/2 ? index+rot/2 : index-rot/2,0,SAVE_PARTNER);end
        SAVE_PARTNER: begin
          partner<=di<rot/2 ? {~result_q[31],result_q[30:0]} : result_q;
          state<=MUL_X;
        end
        MUL_X: calculate(1,x,c,MUL_PARTNER);
        MUL_PARTNER: begin product<=result_q;calculate(1,partner,s,ADD);end
        ADD: calculate(0,product,result_q,STORE);
        STORE: access(1,dst,index,result_q,NEXT);
        NEXT: begin
          if(ti==nt-1&&hi==nh-1&&di==dim-1) begin done<=1;state<=IDLE;end
          else begin
            index<=index+1;state<=FETCH_X;
            if(di==dim-1) begin
              di<=0;
              if(hi==nh-1) begin hi<=0;ti<=ti+1;position_base<=position_base+rot;end
              else hi<=hi+1;
            end else di<=di+1;
          end
        end
        MEM_ISSUE: if(memory_ready) state<=MEM_WAIT;
        MEM_WAIT: if(memory_response_valid) begin
          if(memory_response_error||(!memory_write&&!finite(memory_response_data))) state<=FAILED;
          else begin
            if(!memory_write) result_q<=memory_response_data;
            state<=return_state;
          end
        end
        ALU_ISSUE: if(ready) state<=ALU_WAIT;
        ALU_WAIT: if(valid) begin
          if(error) state<=FAILED;
          else begin result_q<=alu_result;state<=alu_return;end
        end
        FAILED: state<=FAILED;
        default: state<=FAILED;
      endcase
      if(state!=IDLE&&state!=FAILED) begin
        cycles<=cycles+1;
        if(cycles>=WATCHDOG_CYCLES-1) begin done<=0;state<=FAILED;end
      end
    end
  end
endmodule
