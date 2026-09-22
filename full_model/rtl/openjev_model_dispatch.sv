`timescale 1ns/1ps
// Serialized dispatch for all model opcodes. Geometry metadata is produced by
// ExecutionPlan after graph/shape validation; model arithmetic stays in RTL.
module openjev_model_dispatch(
  input wire clk,rst_n,command_valid,
  output wire command_ready,
  input wire [511:0] command_data,
  input wire [255:0] command_metadata,
  output wire completion_valid,
  input wire completion_ready,
  output wire [31:0] completion_tag,
  output wire completion_error,
  output wire memory_valid,
  input wire memory_ready,
  output wire memory_write,
  output wire [31:0] memory_tensor,memory_index,memory_data,
  input wire memory_response_valid,
  output wire memory_response_ready,
  input wire [31:0] memory_response_data,
  input wire memory_response_error,
  output wire weight_request_valid,
  input wire weight_request_ready,
  output wire [4:0] weight_bank,
  output wire [28:0] weight_address,
  input wire weight_response_valid,
  output wire weight_response_ready,
  input wire [255:0] weight_response_data,
  input wire [1:0] weight_response_status
);
  localparam IDLE=0,CHECK=1,LAUNCH=2,RUN=3,COMPLETE=4,FAILED=5;
  reg [2:0] state,selected;
  reg [511:0] instruction;
  reg [255:0] metadata;
  wire [5:0] ready,finished,failed,mv,mw,mrr;
  wire [31:0] mt[0:5],mi[0:5],md[0:5];
  wire [31:0] head_tag;
  wire [31:0] g0=metadata[0+:32],g1=metadata[32+:32],g2=metadata[64+:32],g3=metadata[96+:32];
  wire [31:0] s0=instruction[128+:32],s1=instruction[160+:32],s2=instruction[192+:32],s3=instruction[224+:32];
  wire [31:0] d0=instruction[64+:32],d1=instruction[96+:32];
  reg [31:0] instruction_check,metadata_check;
  always @* begin
    instruction_check=32'h4f4a5031;metadata_check=32'h4f4a4d31;
    for(integer i=0;i<15;i=i+1) instruction_check=instruction_check^instruction[i*32+:32];
    for(integer i=0;i<7;i=i+1) metadata_check=metadata_check^metadata[i*32+:32];
  end
  assign command_ready=rst_n&&state==IDLE;
  assign completion_valid=rst_n&&(state==COMPLETE||state==FAILED);
  assign completion_tag=instruction[32+:32];
  assign completion_error=state==FAILED;
  assign memory_valid=state==RUN&&mv[selected];
  assign memory_write=mw[selected];
  assign memory_tensor=mt[selected];
  assign memory_index=mi[selected];
  assign memory_data=md[selected];
  assign memory_response_ready=state==RUN&&mrr[selected];
  openjev_row_ops rows(
    .clk(clk),.rst_n(rst_n),.command_valid(state==LAUNCH&&selected==0),.command_ready(ready[0]),
    .opcode(instruction[7:0]),.flags(instruction[8+:24]),.row_count(g0),.row_width(g1),.epsilon(metadata[192+:32]),
    .dtype0(metadata[128+:2]),.dtype1(metadata[130+:2]),.dtype2(metadata[132+:2]),
    .source0(s0),.source1(s1),.source2(s2),.destination0(d0),.destination1(d1),
    .done(finished[0]),.fault(failed[0]),
    .memory_valid(mv[0]),.memory_ready(memory_ready&&state==RUN&&selected==0),
    .memory_write(mw[0]),.memory_tensor(mt[0]),.memory_index(mi[0]),.memory_data(md[0]),
    .memory_response_valid(memory_response_valid&&state==RUN&&selected==0),.memory_response_ready(mrr[0]),
    .memory_response_data(memory_response_data),.memory_response_error(memory_response_error));
  openjev_table_ops tables(
    .clk(clk),.rst_n(rst_n),.command_valid(state==LAUNCH&&selected==1),.command_ready(ready[1]),
    .opcode(instruction[7:0]),.token_count(g0),.channel_count(g1),.table_rows(g2),.image_count(g3),
    .source0(s0),.source1(s1),.source2(s2),.source3(s3),.destination(d0),
    .done(finished[1]),.fault(failed[1]),
    .memory_valid(mv[1]),.memory_ready(memory_ready&&state==RUN&&selected==1),
    .memory_write(mw[1]),.memory_tensor(mt[1]),.memory_index(mi[1]),.memory_data(md[1]),
    .memory_response_valid(memory_response_valid&&state==RUN&&selected==1),.memory_response_ready(mrr[1]),
    .memory_response_data(memory_response_data),.memory_response_error(memory_response_error));
  openjev_rope rotary(
    .clk(clk),.rst_n(rst_n),.command_valid(state==LAUNCH&&selected==2),.command_ready(ready[2]),
    .token_count(g0),.head_count(g1),.head_dim(g2),.rotary_dim(g3),
    .source(s0),.cosine(s1),.sine(s2),.destination(d0),
    .done(finished[2]),.fault(failed[2]),
    .memory_valid(mv[2]),.memory_ready(memory_ready&&state==RUN&&selected==2),
    .memory_write(mw[2]),.memory_tensor(mt[2]),.memory_index(mi[2]),.memory_data(md[2]),
    .memory_response_valid(memory_response_valid&&state==RUN&&selected==2),.memory_response_ready(mrr[2]),
    .memory_response_data(memory_response_data),.memory_response_error(memory_response_error));
  openjev_causal_conv convolution(
    .clk(clk),.rst_n(rst_n),.command_valid(state==LAUNCH&&selected==3),.command_ready(ready[3]),
    .token_count(g0),.channel_count(g1),.kernel_size(g2),
    .source(s0),.weights(s1),.scales(s2),.destination(d0),
    .done(finished[3]),.fault(failed[3]),
    .memory_valid(mv[3]),.memory_ready(memory_ready&&state==RUN&&selected==3),
    .memory_write(mw[3]),.memory_tensor(mt[3]),.memory_index(mi[3]),.memory_data(md[3]),
    .memory_response_valid(memory_response_valid&&state==RUN&&selected==3),.memory_response_ready(mrr[3]),
    .memory_response_data(memory_response_data),.memory_response_error(memory_response_error));
  openjev_matrix_rows matrix(
    .clk(clk),.rst_n(rst_n),.command_valid(state==LAUNCH&&selected==4),.command_ready(ready[4]),
    .batch_count(g0),.rows(g1),.columns(g2),.weight_base(metadata[160+:32]),.source(s0),.destination(d0),
    .weight_request_valid(weight_request_valid),.weight_request_ready(weight_request_ready),
    .weight_bank(weight_bank),.weight_address(weight_address),.weight_response_valid(weight_response_valid),
    .weight_response_ready(weight_response_ready),.weight_response_data(weight_response_data),.weight_response_status(weight_response_status),
    .done(finished[4]),.fault(failed[4]),
    .memory_valid(mv[4]),.memory_ready(memory_ready&&state==RUN&&selected==4),
    .memory_write(mw[4]),.memory_tensor(mt[4]),.memory_index(mi[4]),.memory_data(md[4]),
    .memory_response_valid(memory_response_valid&&state==RUN&&selected==4),.memory_response_ready(mrr[4]),
    .memory_response_data(memory_response_data),.memory_response_error(memory_response_error));
  openjev_head_dispatch heads(
    .clk(clk),.rst_n(rst_n),.command_valid(state==LAUNCH&&selected==5),.command_ready(ready[5]),
    .command_data(instruction),.completion_valid(finished[5]),.completion_ready(state==RUN&&selected==5),
    .completion_error(failed[5]),.completion_tag(head_tag),
    .memory_valid(mv[5]),.memory_ready(memory_ready&&state==RUN&&selected==5),
    .memory_write(mw[5]),.memory_tensor(mt[5]),.memory_index(mi[5]),.memory_data(md[5]),
    .memory_response_valid(memory_response_valid&&state==RUN&&selected==5),.memory_response_ready(mrr[5]),
    .memory_response_data(memory_response_data),.memory_response_error(memory_response_error));
  always @(posedge clk) begin
    if(!rst_n) begin state<=IDLE;selected<=0;instruction<=0;metadata<=0;end
    else case(state)
      IDLE: if(command_valid) begin
        instruction<=command_data;metadata<=command_metadata;state<=CHECK;
        case(command_data[7:0])
          1,3,4,5,6,7,8,9,10,11,12,13,14,15: selected<=0;
          16,17,19,20: selected<=1;
          18: selected<=2;21: selected<=3;2: selected<=4;22,23: selected<=5;
          default: begin selected<=0;state<=FAILED;end
        endcase
      end
      CHECK: if(instruction_check!=instruction[480+:32]||metadata_check!=metadata[224+:32]) state<=FAILED;
        else state<=LAUNCH;
      LAUNCH: if(ready[selected]) state<=RUN;
      RUN: if(failed[selected]) state<=FAILED;
        else if(finished[selected]) begin
          if(selected==5&&head_tag!=completion_tag) state<=FAILED;
          else state<=COMPLETE;
        end
      COMPLETE: if(completion_ready) state<=IDLE;
      FAILED: state<=FAILED;
      default: state<=FAILED;
    endcase
  end
endmodule
