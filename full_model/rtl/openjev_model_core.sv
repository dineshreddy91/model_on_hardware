`timescale 1ns/1ps
// Complete program/tensor dispatch core with one AXI HBM master.
// Reset must include the downstream AXI fabric after a fault.
module openjev_model_core #(
  parameter integer MAX_INSTRUCTIONS=4096,MAX_TENSORS=4096
)(
  input wire clk,rst_n,
  input wire program_valid,
  output wire program_ready,
  input wire [31:0] program_index,
  input wire [511:0] program_data,
  input wire metadata_valid,
  output wire metadata_ready,
  input wire [31:0] metadata_index,
  input wire [255:0] metadata_data,
  input wire tensor_valid,
  output wire tensor_ready,
  input wire [31:0] tensor_index,
  input wire [1023:0] tensor_data,
  input wire start,
  input wire [31:0] program_length,tensor_count,
  output reg active,
  output wire done,fault,
  output wire [3:0] fault_code,
  output reg [63:0] cycles,
  output reg [31:0] instructions_retired,
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
  reg [255:0] metadata_table[0:MAX_INSTRUCTIONS-1];
  reg [MAX_INSTRUCTIONS-1:0] metadata_loaded;
  reg [255:0] metadata_q;
  reg metadata_pending;
  wire sequence_valid,sequence_ready,dispatch_ready,completion_valid,completion_error;
  wire [511:0] instruction;
  wire [31:0] completion_tag;
  wire seq_program_ready,mv,mr,mw,mrv,mrr,merror,mfault;
  wire [31:0] mt,mi,md,mrd;
  wire [3:0] memory_fault_code;
  wire wreq,weight_req_ready,weight_resp_valid,wrready;
  wire [4:0] wbank;
  wire [28:0] waddress;
  wire [255:0] wresponse;
  wire [1:0] wstatus;
  wire [63:0] taraddr;
  wire [7:0] tarlen;
  wire [2:0] tarsize;
  wire [1:0] tarburst;
  wire [15:0] tarid;
  wire tarvalid,tarready,trvalid,trready;
  reg read_busy,weight_owner,weight_half;
  wire choose_weight=!tarvalid&&wreq;
  assign program_ready=!active&&seq_program_ready;
  assign metadata_ready=rst_n&&!active&&!start&&metadata_index<MAX_INSTRUCTIONS;
  assign sequence_ready=metadata_pending&&dispatch_ready;
  assign arvalid=!read_busy&&(tarvalid||wreq);
  assign araddr=choose_weight ? 64'h1000000000+{30'b0,wbank,waddress[28:6],6'b0} : taraddr;
  assign arlen=choose_weight ? 0 : tarlen;
  assign arsize=choose_weight ? 6 : tarsize;
  assign arburst=choose_weight ? 1 : tarburst;
  assign arid=choose_weight ? 0 : tarid;
  assign tarready=!read_busy&&!choose_weight&&arready;
  assign weight_req_ready=!read_busy&&choose_weight&&arready;
  assign trvalid=read_busy&&!weight_owner&&rvalid;
  assign weight_resp_valid=read_busy&&weight_owner&&rvalid;
  assign rready=read_busy&&(weight_owner ? wrready : trready);
  assign wresponse=weight_half ? rdata[511:256] : rdata[255:0];
  assign wstatus=rid!=0||!rlast ? 2'b10 : rresp;
  openjev_graph_sequencer #(.MAX_INSTRUCTIONS(MAX_INSTRUCTIONS),.CAPABILITIES(256'hfffffe),.WATCHDOG_CYCLES(64'd100000000000)) sequencer(
    .clk(clk),.rst_n(rst_n),.load_valid(program_valid&&!active),.load_ready(seq_program_ready),
    .load_index(program_index),.load_data(program_data),.start(start&&!active),.program_length(program_length),.tensor_count(tensor_count),
    .dispatch_valid(sequence_valid),.dispatch_ready(sequence_ready),.dispatch_data(instruction),
    .completion_valid(completion_valid),.completion_tag(completion_tag),.completion_error(completion_error),
    .done(done),.fault(fault),.fault_code(fault_code));
  openjev_model_dispatch dispatch(
    .clk(clk),.rst_n(rst_n),.command_valid(sequence_valid&&metadata_pending),.command_ready(dispatch_ready),
    .command_data(instruction),.command_metadata(metadata_q),.completion_valid(completion_valid),.completion_ready(1'b1),
    .completion_tag(completion_tag),.completion_error(completion_error),
    .memory_valid(mv),.memory_ready(mr),.memory_write(mw),.memory_tensor(mt),.memory_index(mi),.memory_data(md),
    .memory_response_valid(mrv),.memory_response_ready(mrr),.memory_response_data(mrd),.memory_response_error(merror),
    .weight_request_valid(wreq),.weight_request_ready(weight_req_ready),.weight_bank(wbank),.weight_address(waddress),
    .weight_response_valid(weight_resp_valid),.weight_response_ready(wrready),.weight_response_data(wresponse),.weight_response_status(wstatus));
  openjev_tensor_port #(.MAX_TENSORS(MAX_TENSORS)) tensor_port(
    .clk(clk),.rst_n(rst_n),.run_enable(active),.tensor_count(tensor_count),
    .table_valid(tensor_valid&&!start),.table_ready(tensor_ready),.table_index(tensor_index),.table_data(tensor_data),
    .request_valid(mv),.request_ready(mr),.request_write(mw),.request_tensor(mt),.request_index(mi),.write_data(md),
    .response_valid(mrv),.response_ready(mrr),.response_data(mrd),.response_error(merror),.fault(mfault),.fault_code(memory_fault_code),
    .araddr(taraddr),.arlen(tarlen),.arsize(tarsize),.arburst(tarburst),.arid(tarid),.arvalid(tarvalid),.arready(tarready),
    .rdata(rdata),.rresp(rresp),.rid(rid),.rlast(rlast),.rvalid(trvalid),.rready(trready),
    .awaddr(awaddr),.awlen(awlen),.awsize(awsize),.awburst(awburst),.awid(awid),.awvalid(awvalid),.awready(awready),
    .wdata(wdata),.wstrb(wstrb),.wlast(wlast),.wvalid(wvalid),.wready(wready),.bresp(bresp),.bid(bid),.bvalid(bvalid),.bready(bready));
  always @(posedge clk) begin
    if(!rst_n) begin
      active<=0;cycles<=0;instructions_retired<=0;metadata_loaded<=0;metadata_q<=0;metadata_pending<=0;
      read_busy<=0;weight_owner<=0;weight_half<=0;
    end else begin
      if(metadata_valid&&metadata_ready) begin metadata_table[metadata_index]<=metadata_data;metadata_loaded[metadata_index]<=1;end
      if(start&&!active&&!fault) begin active<=1;cycles<=0;instructions_retired<=0;end
      if(active) cycles<=cycles+1;
      if(done||fault) active<=0;
      if(completion_valid&&!completion_error) instructions_retired<=instructions_retired+1;
      if(sequence_valid&&!metadata_pending) begin
        metadata_q<=instruction[32+:32]<MAX_INSTRUCTIONS&&metadata_loaded[instruction[32+:32]] ? metadata_table[instruction[32+:32]] : 0;
        metadata_pending<=1;
      end
      if(sequence_valid&&sequence_ready) metadata_pending<=0;
      if(arvalid&&arready) begin read_busy<=1;weight_owner<=choose_weight;weight_half<=waddress[5];end
      if(rvalid&&rready) read_busy<=0;
    end
  end
endmodule
