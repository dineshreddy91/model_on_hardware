`timescale 1ns/1ps
// Compose checked tensor-view translation with committed striped-HBM accesses.
module openjev_tensor_memory #(
  parameter integer WATCHDOG_CYCLES=1000000
)(
  input wire clk,rst_n,request_valid,cache_invalidate,
  output wire request_ready,
  input wire request_write,
  input wire [1023:0] descriptor,root_descriptor,
  input wire [31:0] element_index,write_data,
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
  localparam IDLE=0,MAP=1,MEMORY=2,RESULT=3;
  reg [1:0] state;
  reg write_q;
  reg [31:0] payload;
  wire map_ready,map_valid,map_error,element_ready,element_valid,element_error;
  wire [31:0] base_address,bank_extent,logical_bytes,byte_offset,element_data;
  wire [2:0] element_bytes;
  assign request_ready=rst_n && state==IDLE && map_ready && !fault;
  assign response_valid=rst_n && state==RESULT;
  openjev_tensor_address mapper(
    .clk(clk),.rst_n(rst_n),.request_valid(request_valid&&request_ready),
    .request_ready(map_ready),.descriptor(descriptor),.root_descriptor(root_descriptor),
    .element_index(element_index),.request_write(request_write),
    .response_valid(map_valid),.response_ready(state==MAP && (map_error||element_ready)),
    .response_error(map_error),.base_address(base_address),.bank_extent(bank_extent),
    .logical_bytes(logical_bytes),.byte_offset(byte_offset),.element_bytes(element_bytes));
  openjev_hbm_element #(.WATCHDOG_CYCLES(WATCHDOG_CYCLES)) memory(
    .clk(clk),.rst_n(rst_n),.cache_invalidate(cache_invalidate),.request_valid(state==MAP&&map_valid&&!map_error),
    .request_ready(element_ready),.request_write(write_q),
    .base_address(base_address),.bank_extent(bank_extent),.logical_bytes(logical_bytes),
    .byte_offset(byte_offset),.element_bytes(element_bytes),.write_data(payload),
    .response_valid(element_valid),.response_ready(state==MEMORY),
    .response_data(element_data),.response_error(element_error),
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
      state<=IDLE;write_q<=0;payload<=0;response_data<=0;response_error<=0;
    end else case(state)
      IDLE: if(request_valid&&request_ready) begin
        write_q<=request_write;payload<=write_data;state<=MAP;
      end
      MAP: if(map_valid) begin
        if(map_error) begin response_error<=1;response_data<=0;state<=RESULT;end
        else if(element_ready) state<=MEMORY;
      end
      MEMORY: if(element_valid) begin
        response_error<=element_error;response_data<=element_data;state<=RESULT;
      end
      RESULT: if(response_ready) state<=IDLE;
    endcase
  end
endmodule
