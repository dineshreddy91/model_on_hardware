`timescale 1ns/1ps
// Tensor-ID memory port with a synchronous descriptor table and root resolution.
// Hold run_enable asserted throughout a graph. Configuration is locked while
// running; reset invalidates every descriptor. Values remain raw dtype words.
module openjev_tensor_port #(
  parameter integer MAX_TENSORS=4096,
  parameter integer WATCHDOG_CYCLES=1000000
)(
  input wire clk,rst_n,run_enable,
  input wire [31:0] tensor_count,
  input wire table_valid,
  output wire table_ready,
  input wire [31:0] table_index,
  input wire [1023:0] table_data,
  input wire request_valid,
  output wire request_ready,
  input wire request_write,
  input wire [31:0] request_tensor,request_index,write_data,
  output wire response_valid,
  input wire response_ready,
  output reg [31:0] response_data,
  output reg response_error,
  output wire fault,
  output wire [3:0] fault_code,
  output wire [63:0] araddr,
  output wire [7:0] arlen,
  output wire [2:0] arsize,
  output wire [1:0] arburst,
  output wire [15:0] arid,
  output wire arvalid,
  input wire arready,
  input wire [511:0] rdata,
  input wire [1:0] rresp,
  input wire [15:0] rid,
  input wire rlast,rvalid,
  output wire rready,
  output wire [63:0] awaddr,
  output wire [7:0] awlen,
  output wire [2:0] awsize,
  output wire [1:0] awburst,
  output wire [15:0] awid,
  output wire awvalid,
  input wire awready,
  output wire [511:0] wdata,
  output wire [63:0] wstrb,
  output wire wlast,wvalid,
  input wire wready,
  input wire [1:0] bresp,
  input wire [15:0] bid,
  input wire bvalid,
  output wire bready
);
  localparam IDLE=0,GET_ROOT=1,CHECK_ROOT=2,ISSUE=3,WAIT_MEMORY=4,RESULT=5,
             FETCH_DESCRIPTOR=6,LATCH_DESCRIPTOR=7,FETCH_ROOT=8,LATCH_ROOT=9;
  localparam ADDRESS_WIDTH=MAX_TENSORS>1 ? $clog2(MAX_TENSORS) : 1;
  reg [3:0] state;
  (* ram_style="block" *) reg [1023:0] descriptors[0:MAX_TENSORS-1];
  reg [MAX_TENSORS-1:0] loaded;
  reg [1023:0] descriptor,root_descriptor,descriptor_word;
  reg write_q;
  reg [31:0] index_q,payload,requested_id;
  wire [ADDRESS_WIDTH-1:0] descriptor_address = state==FETCH_ROOT ?
    descriptor[192+:ADDRESS_WIDTH] : requested_id[ADDRESS_WIDTH-1:0];
  wire memory_ready,memory_valid,memory_error;
  wire [31:0] memory_data;
  assign table_ready=rst_n && !run_enable && state==IDLE && table_index<MAX_TENSORS;
  assign request_ready=rst_n && run_enable && state==IDLE && !fault;
  assign response_valid=rst_n && state==RESULT;
  openjev_tensor_memory #(.WATCHDOG_CYCLES(WATCHDOG_CYCLES)) memory(
    .clk(clk),.rst_n(rst_n),.cache_invalidate(!run_enable),.request_valid(state==ISSUE),.request_ready(memory_ready),
    .request_write(write_q),.descriptor(descriptor),.root_descriptor(root_descriptor),
    .element_index(index_q),.write_data(payload),.response_valid(memory_valid),
    .response_ready(state==WAIT_MEMORY),.response_data(memory_data),.response_error(memory_error),
    .fault(fault),.fault_code(fault_code),
    .araddr(araddr),
    .arlen(arlen),
    .arsize(arsize),
    .arburst(arburst),
    .arid(arid),
    .arvalid(arvalid),
    .arready(arready),
    .rdata(rdata),
    .rresp(rresp),
    .rid(rid),
    .rlast(rlast),
    .rvalid(rvalid),
    .rready(rready),
    .awaddr(awaddr),
    .awlen(awlen),
    .awsize(awsize),
    .awburst(awburst),
    .awid(awid),
    .awvalid(awvalid),
    .awready(awready),
    .wdata(wdata),
    .wstrb(wstrb),
    .wlast(wlast),
    .wvalid(wvalid),
    .wready(wready),
    .bresp(bresp),
    .bid(bid),
    .bvalid(bvalid),
    .bready(bready));
  always @(posedge clk) begin
    if(!rst_n) begin
      state<=IDLE;loaded<=0;descriptor<=0;root_descriptor<=0;descriptor_word<=0;
      write_q<=0;index_q<=0;payload<=0;requested_id<=0;response_data<=0;response_error<=0;
    end else begin
      if(table_valid&&table_ready) begin
        descriptors[table_index[ADDRESS_WIDTH-1:0]]<=table_data;loaded[table_index]<=1;
      end
      if(state==FETCH_DESCRIPTOR || state==FETCH_ROOT)
        descriptor_word<=descriptors[descriptor_address];
      case(state)
        IDLE: if(request_valid&&request_ready) begin
          requested_id<=request_tensor;index_q<=request_index;write_q<=request_write;payload<=write_data;
          response_data<=0;response_error<=0;
          if(tensor_count==0||tensor_count>MAX_TENSORS||request_tensor>=tensor_count||
             request_tensor>=MAX_TENSORS || !loaded[request_tensor]) begin
            response_error<=1;state<=RESULT;
          end else state<=FETCH_DESCRIPTOR;
        end
        FETCH_DESCRIPTOR: state<=LATCH_DESCRIPTOR;
        LATCH_DESCRIPTOR: begin descriptor<=descriptor_word;state<=GET_ROOT;end
        GET_ROOT: begin
          if(descriptor[0+:32]!=requested_id || descriptor[192+:32]>=tensor_count ||
             descriptor[192+:32]>=MAX_TENSORS || !loaded[descriptor[192+:32]]) begin
            response_error<=1;state<=RESULT;
          end else state<=FETCH_ROOT;
        end
        FETCH_ROOT: state<=LATCH_ROOT;
        LATCH_ROOT: begin root_descriptor<=descriptor_word;state<=CHECK_ROOT;end
        CHECK_ROOT: begin
          if(root_descriptor[0+:32]!=descriptor[192+:32]) begin response_error<=1;state<=RESULT;end
          else state<=ISSUE;
        end
        ISSUE: if(memory_ready) state<=WAIT_MEMORY;
        WAIT_MEMORY: begin
          if(fault) begin response_error<=1;response_data<=0;state<=RESULT;end
          else if(memory_valid) begin response_data<=memory_data;response_error<=memory_error;state<=RESULT;end
        end
        RESULT: if(response_ready) state<=IDLE;
        default: begin response_error<=1;state<=RESULT;end
      endcase
    end
  end
endmodule
