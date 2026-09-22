`timescale 1ns/1ps
// Depthwise cross-correlation with left zero padding and INT8/FP16 weights.
// Tensor words are raw: input/output FP32, weight low INT8, scale low FP16.
// Output is pre-SiLU. Fresh destination storage is required by graph validation.
module openjev_causal_conv #(
  parameter [63:0] WATCHDOG_CYCLES=64'd20000000000
)(
  input wire clk,rst_n,command_valid,
  output wire command_ready,
  input wire [31:0] token_count,channel_count,kernel_size,
  input wire [31:0] source,weights,scales,destination,
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
  localparam IDLE=0,LOAD_SCALE=1,SAVE_SCALE=2,TAP=3,SAVE_WEIGHT=4,
    SCALE_ISSUE=5,SCALE_WAIT=6,SAVE_X=7,MULTIPLY=8,ACCUMULATE=9,
    SUM_SAVE=10,STORE=11,NEXT=12,MEM_ISSUE=13,MEM_WAIT=14,
    ALU_ISSUE=15,ALU_WAIT=16,FAILED=17,X_TOKEN=18,X_MULT=19,X_READ=20;
  reg [4:0] state,return_state,alu_return;
  reg [12:0] x_token;
  reg [25:0] x_product;
  reg [31:0] nt,nc,ks,ti,ci,ki,index,src,wt,sc,dst;
  reg [31:0] result_q,sum,weight_value,alu_a,alu_b;
  reg [15:0] scale_value;
  reg signed [31:0] weight_integer;
  reg [3:0] alu_op;
  wire scale_ready,scale_valid,scale_error,alu_ready,alu_valid,alu_error;
  wire [31:0] scale_result,alu_result;
  assign command_ready=rst_n&&state==IDLE;
  assign memory_valid=rst_n&&state==MEM_ISSUE;
  assign memory_response_ready=rst_n&&state==MEM_WAIT;
  assign fault=state==FAILED;
  openjev_scaled_int32 dequantize(
    .clk(clk),.rst_n(rst_n),.input_valid(state==SCALE_ISSUE),.input_ready(scale_ready),
    .accumulator(weight_integer),.scale(scale_value),.output_valid(scale_valid),
    .output_ready(state==SCALE_WAIT),.output_data(scale_result),.output_error(scale_error));
  openjev_scalar scalar(
    .clk(clk),.rst_n(rst_n),.input_valid(state==ALU_ISSUE),.input_ready(alu_ready),
    .opcode(alu_op),.input_a(alu_a),.input_b(alu_b),.output_valid(alu_valid),
    .output_ready(state==ALU_WAIT),.output_data(alu_result),.output_error(alu_error));
  task access;
    input wr;
    input [31:0] tensor_id,offset,data;
    input [4:0] next_state;
    begin
      memory_write<=wr;memory_tensor<=tensor_id;memory_index<=offset;memory_data<=data;
      return_state<=next_state;state<=MEM_ISSUE;
    end
  endtask
  task calculate;
    input [3:0] op;
    input [31:0] a,b;
    input [4:0] next_state;
    begin alu_op<=op;alu_a<=a;alu_b<=b;alu_return<=next_state;state<=ALU_ISSUE;end
  endtask
  always @(posedge clk) begin
    if(!rst_n) begin
      x_token<=0;x_product<=0;
      state<=IDLE;return_state<=IDLE;alu_return<=IDLE;nt<=0;nc<=0;ks<=0;
      ti<=0;ci<=0;ki<=0;index<=0;cycles<=0;src<=0;wt<=0;sc<=0;dst<=0;
      result_q<=0;sum<=0;weight_value<=0;alu_a<=0;alu_b<=0;scale_value<=0;
      weight_integer<=0;alu_op<=0;memory_write<=0;memory_tensor<=0;
      memory_index<=0;memory_data<=0;done<=0;
    end else begin
      done<=0;
      case(state)
        IDLE: if(command_valid) begin
          if(token_count==0||token_count>4096||channel_count==0||channel_count>6144||
             kernel_size==0||kernel_size>4||destination==source||destination==weights||destination==scales)
            state<=FAILED;
          else begin
            nt<=token_count;nc<=channel_count;ks<=kernel_size;src<=source;wt<=weights;sc<=scales;dst<=destination;
            ti<=0;ci<=0;ki<=0;index<=0;sum<=0;cycles<=0;state<=LOAD_SCALE;
          end
        end
        LOAD_SCALE: access(0,sc,ci,0,SAVE_SCALE);
        SAVE_SCALE: begin
          if(result_q[14:10]==31) state<=FAILED;
          else begin scale_value<=result_q[15:0];state<=TAP;end
        end
        TAP: begin
          if(ti+ki<ks-1) begin
            if(ki==ks-1) state<=STORE;
            else ki<=ki+1;
          end else access(0,wt,ci[12:0]*ks[2:0]+ki[1:0],0,SAVE_WEIGHT);
        end
        SAVE_WEIGHT: begin weight_integer<={{24{result_q[7]}},result_q[7:0]};state<=SCALE_ISSUE;end
        SCALE_ISSUE: if(scale_ready) state<=SCALE_WAIT;
        SCALE_WAIT: if(scale_valid) begin
          if(scale_error) state<=FAILED;
          else begin weight_value<=scale_result;state<=X_TOKEN;end
        end
        X_TOKEN: begin x_token<=ti[12:0]+{11'b0,ki[1:0]}-({10'b0,ks[2:0]}-13'd1);state<=X_MULT;end
        X_MULT: begin x_product<=x_token*nc[12:0];state<=X_READ;end
        X_READ: access(0,src,{6'b0,x_product}+ci,0,SAVE_X);
        SAVE_X: begin
          if(!finite(result_q)) state<=FAILED;
          else state<=MULTIPLY;
        end
        MULTIPLY: calculate(1,result_q,weight_value,ACCUMULATE);
        ACCUMULATE: calculate(0,sum,result_q,SUM_SAVE);
        SUM_SAVE: begin
          sum<=result_q;
          if(ki==ks-1) state<=STORE;
          else begin ki<=ki+1;state<=TAP;end
        end
        STORE: access(1,dst,index,sum,NEXT);
        NEXT: begin
          if(ti==nt-1&&ci==nc-1) begin done<=1;state<=IDLE;end
          else begin
            index<=index+1;ki<=0;sum<=0;state<=LOAD_SCALE;
            if(ci==nc-1) begin ci<=0;ti<=ti+1;end
            else ci<=ci+1;
          end
        end
        MEM_ISSUE: if(memory_ready) state<=MEM_WAIT;
        MEM_WAIT: if(memory_response_valid) begin
          if(memory_response_error) state<=FAILED;
          else begin if(!memory_write) result_q<=memory_response_data;state<=return_state;end
        end
        ALU_ISSUE: if(alu_ready) state<=ALU_WAIT;
        ALU_WAIT: if(alu_valid) begin
          if(alu_error) state<=FAILED;
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
