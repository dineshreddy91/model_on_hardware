`timescale 1ns/1ps
// Embedding, four-corner position interpolation, image insertion and last-token gather.
// Raw tensor words; weights INT8, scales FP16, indices INT32, activations FP32.
// Fresh, nonaliasing output storage must be enforced by descriptor validation.
module openjev_table_ops #(
  parameter [63:0] WATCHDOG_CYCLES=64'd20000000000
)(
  input wire clk,rst_n,command_valid,
  output wire command_ready,
  input wire [7:0] opcode,
  input wire [31:0] token_count,channel_count,table_rows,image_count,
  input wire [31:0] source0,source1,source2,source3,destination,
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
  localparam IDLE=0,CLEAR_MAP=1,SLOT_READ=2,SLOT_CHECK=3,ROW=4,INDEX_CHECK=5,
    SCALE_SAVE=6,WEIGHT_READ=7,WEIGHT_SAVE=8,SCALE_ISSUE=9,SCALE_WAIT=10,
    COEFF_SAVE=11,PRODUCT_SAVE=12,SUM_SAVE=13,COPY_SAVE=14,STORE=15,NEXT=16,
    MEM_ISSUE=17,MEM_WAIT=18,ALU_ISSUE=19,ALU_WAIT=20,FAILED=21,ADDRESS_MULT=22,ADDRESS_ISSUE=23;
  reg [4:0] state,return_state,alu_return,address_return;
  reg [17:0] address_row;
  reg [30:0] address_product;
  reg [31:0] address_tensor;
  reg [7:0] op;
  reg [31:0] nt,nc,nr,ni,ti,ci,corner,index,row_id,map_index;
  reg [31:0] s0,s1,s2,s3,dst,result_q,sum,scaled_value,alu_a,alu_b;
  reg [31:0] image_map[0:4095];
  reg [4095:0] occupied;
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
  task indexed_access;
    input [31:0] tensor_id,row;
    input [4:0] next_state;
    begin
      address_tensor<=tensor_id;address_row<=row[17:0];address_return<=next_state;
      state<=ADDRESS_MULT;
    end
  endtask
  task calculate;
    input [3:0] operation;
    input [31:0] a,b;
    input [4:0] next_state;
    begin alu_op<=operation;alu_a<=a;alu_b<=b;alu_return<=next_state;state<=ALU_ISSUE;end
  endtask
  always @(posedge clk) begin
    if(!rst_n) begin
      address_return<=IDLE;address_row<=0;address_product<=0;address_tensor<=0;
      state<=IDLE;return_state<=IDLE;alu_return<=IDLE;op<=0;nt<=0;nc<=0;nr<=0;ni<=0;
      ti<=0;ci<=0;corner<=0;index<=0;row_id<=0;map_index<=0;cycles<=0;occupied<=0;
      s0<=0;s1<=0;s2<=0;s3<=0;dst<=0;result_q<=0;sum<=0;scaled_value<=0;
      alu_a<=0;alu_b<=0;scale_value<=0;weight_integer<=0;alu_op<=0;
      memory_write<=0;memory_tensor<=0;memory_index<=0;memory_data<=0;done<=0;
    end else begin
      done<=0;
      case(state)
        IDLE: if(command_valid) begin
          if(token_count==0||token_count>4096||channel_count==0||channel_count>4096||
             !(opcode==16||opcode==17||opcode==19||opcode==20)||
             ((opcode==16||opcode==17)&&(table_rows==0||table_rows>248320))||
             (opcode==19&&image_count>token_count)||
             destination==source0||destination==source1||
             ((opcode!=20)&&destination==source2)||(opcode==17&&destination==source3)) state<=FAILED;
          else begin
            op<=opcode;nt<=token_count;nc<=channel_count;nr<=table_rows;ni<=image_count;
            s0<=source0;s1<=source1;s2<=source2;s3<=source3;dst<=destination;
            ti<=0;ci<=0;corner<=0;index<=0;map_index<=0;sum<=0;cycles<=0;occupied<=0;
            state<=opcode==19 ? CLEAR_MAP : ROW;
          end
        end
        CLEAR_MAP: begin
          image_map[map_index]<=32'hffffffff;
          if(map_index==nt-1) begin map_index<=0;state<=ni==0 ? ROW : SLOT_READ;end
          else map_index<=map_index+1;
        end
        SLOT_READ: access(0,s2,map_index,0,SLOT_CHECK);
        SLOT_CHECK: begin
          if(result_q>=nt||occupied[result_q[11:0]]) state<=FAILED;
          else begin
            image_map[result_q[11:0]]<=map_index;occupied[result_q[11:0]]<=1;
            if(map_index==ni-1) state<=ROW;
            else begin map_index<=map_index+1;state<=SLOT_READ;end
          end
        end
        ROW: case(op)
          16: access(0,s0,ti,0,INDEX_CHECK);
          17: access(0,s2,ti*4+corner,0,INDEX_CHECK);
          19: if(image_map[ti]==32'hffffffff) access(0,s0,index,0,COPY_SAVE);
              else indexed_access(s1,image_map[ti],COPY_SAVE);
          20: access(0,s1,0,0,INDEX_CHECK);
          default: state<=FAILED;
        endcase
        INDEX_CHECK: begin
          if(result_q>=(op==20 ? nt : nr)) state<=FAILED;
          else begin
            row_id<=result_q;
            if(op==20) indexed_access(s0,result_q,COPY_SAVE);
            else access(0,op==16 ? s2 : s1,result_q,0,SCALE_SAVE);
          end
        end
        SCALE_SAVE: begin
          if(result_q[14:10]==31) state<=FAILED;
          else begin scale_value<=result_q[15:0];state<=WEIGHT_READ;end
        end
        WEIGHT_READ: indexed_access(op==16 ? s1 : s0,row_id,WEIGHT_SAVE);
        ADDRESS_MULT: begin address_product<=address_row*nc[12:0];state<=ADDRESS_ISSUE;end
        ADDRESS_ISSUE: access(0,address_tensor,{1'b0,address_product}+ci,0,address_return);
        WEIGHT_SAVE: begin weight_integer<={{24{result_q[7]}},result_q[7:0]};state<=SCALE_ISSUE;end
        SCALE_ISSUE: if(scale_ready) state<=SCALE_WAIT;
        SCALE_WAIT: if(scale_valid) begin
          if(scale_error) state<=FAILED;
          else if(op==16) begin result_q<=scale_result;state<=STORE;end
          else begin scaled_value<=scale_result;access(0,s3,ti*4+corner,0,COEFF_SAVE);end
        end
        COEFF_SAVE: begin
          if(!finite(result_q)) state<=FAILED;
          else calculate(1,scaled_value,result_q,PRODUCT_SAVE);
        end
        PRODUCT_SAVE: calculate(0,sum,result_q,SUM_SAVE);
        SUM_SAVE: begin
          sum<=result_q;
          if(corner==3) state<=STORE;
          else begin corner<=corner+1;state<=ROW;end
        end
        COPY_SAVE: if(!finite(result_q)) state<=FAILED;else state<=STORE;
        STORE: access(1,dst,index,result_q,NEXT);
        NEXT: begin
          if(ci==nc-1&&(op==20||ti==nt-1)) begin done<=1;state<=IDLE;end
          else begin
            index<=index+1;corner<=0;sum<=0;state<=ROW;
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
