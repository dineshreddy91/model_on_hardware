`timescale 1ns/1ps
// DMA wrapper for openjev_vector: reads striped HBM FP32 operands and commits
// padded 32-byte result words through the AXI writer. One command at a time.
// Scheduler must validate/protect memory ranges and enforce a watchdog.
module openjev_hbm_vector (
  input logic clk,rst_n,command_valid,
  output logic command_ready,
  input logic [3:0] opcode,
  input logic [28:0] source_a,source_b,source_c,destination,
  input logic [31:0] length,epsilon,
  output logic read_valid,
  input logic read_ready,
  output logic [4:0] read_bank,
  output logic [28:0] read_address,
  input logic read_response_valid,
  output logic read_response_ready,
  input logic [255:0] read_data,
  input logic [1:0] read_status,
  output logic [63:0] awaddr,
  output logic [7:0] awlen,
  output logic [2:0] awsize,
  output logic [1:0] awburst,
  output logic awvalid,
  input logic awready,
  output logic [511:0] wdata,
  output logic [63:0] wstrb,
  output logic wlast,wvalid,
  input logic wready,bvalid,
  output logic bready,
  input logic [1:0] bresp,
  input logic [15:0] bid,
  output logic completion_valid,
  input logic completion_ready,
  output logic completion_error
);
  typedef enum logic [2:0] {IDLE,READ_REQUEST,READ_RESPONSE,FEED,WAIT_COMMIT,COMPLETE,FAULTED} state_t;
  state_t state;
  logic [3:0] op;
  logic [28:0] bases[0:2];
  logic [31:0] count,offset,fed,produced;
  logic [1:0] operand;
  logic [2:0] lane,pack_lane;
  logic [255:0] operands[0:2],packed_word;
  logic pending,vector_finished,writer_finished,uses_b,uses_c;
  logic vc_ready,vc_error,vi_ready,vo_valid,vo_last,vdone,vfault;
  logic [31:0] vo_data;
  logic wc_ready,wc_error,wi_ready,wdone,wfault;
  logic launch,accept_output;
  logic [31:0] padded_bytes;
  assign command_ready=rst_n && state==IDLE && vc_ready && wc_ready;
  assign launch=command_valid && command_ready;
  assign padded_bytes=((length+7)>>3)<<5;
  assign uses_b=op<2 || op==8 || op==9;
  assign uses_c=op==9;
  assign read_valid=rst_n && state==READ_REQUEST;
  assign read_bank=offset[12:8];
  assign read_address=bases[operand]+{2'b0,offset[31:13],offset[7:0]};
  assign read_response_ready=rst_n && state==READ_RESPONSE;
  assign completion_valid=rst_n && (state==COMPLETE || state==FAULTED);
  assign completion_error=state==FAULTED;
  assign accept_output=vo_valid && !pending && state==WAIT_COMMIT;

  openjev_vector vector_unit(
    .clk(clk),.rst_n(rst_n),.command_valid(launch),.command_ready(vc_ready),.command_error(vc_error),
    .command_opcode(opcode),.command_length(length),.command_epsilon(epsilon),
    .input_valid(state==FEED),.input_ready(vi_ready),
    .input_a(operands[0][lane*32+:32]),.input_b(operands[1][lane*32+:32]),
    .input_c(operands[2][lane*32+:32]),.input_last(fed==count-1),
    .output_valid(vo_valid),.output_ready(!pending && state==WAIT_COMMIT),
    .output_data(vo_data),.output_last(vo_last),.done(vdone),.fault(vfault));
  openjev_hbm_activation_writer writer(
    .clk(clk),.rst_n(rst_n),.command_valid(launch),.command_ready(wc_ready),.command_error(wc_error),
    .base_address(destination),.byte_count(padded_bytes),.input_valid(pending && state==WAIT_COMMIT),
    .input_ready(wi_ready),.input_data(packed_word),.input_last(produced==count),
    .awaddr(awaddr),.awlen(awlen),.awsize(awsize),.awburst(awburst),.awvalid(awvalid),.awready(awready),
    .wdata(wdata),.wstrb(wstrb),.wlast(wlast),.wvalid(wvalid),.wready(wready),
    .bvalid(bvalid),.bready(bready),.bresp(bresp),.bid(bid),.done(wdone),.fault(wfault),.committed_bytes());

  always_ff @(posedge clk) begin
    if(!rst_n) begin
      state<=IDLE; op<=0; count<=0; offset<=0; fed<=0; produced<=0; operand<=0;
      lane<=0; pack_lane<=0; pending<=0; packed_word<=0;
      vector_finished<=0; writer_finished<=0;
      for(integer i=0;i<3;i=i+1) begin bases[i]<=0; operands[i]<=0; end
    end else begin
      if(vdone) vector_finished<=1;
      if(wdone) writer_finished<=1;
      if(pending && wi_ready && state==WAIT_COMMIT) begin
        pending<=0; packed_word<=0; pack_lane<=0;
      end
      if(accept_output) begin
        packed_word[pack_lane*32+:32]<=vo_data;
        produced<=produced+1;
        if(pack_lane==7 || vo_last) pending<=1;
        else pack_lane<=pack_lane+1;
      end
      case(state)
        IDLE: if(launch) begin
          op<=opcode; count<=length; bases[0]<=source_a; bases[1]<=source_b; bases[2]<=source_c;
          offset<=0; fed<=0; produced<=0; operand<=0; lane<=0; pack_lane<=0; packed_word<=0; pending<=0;
          vector_finished<=0; writer_finished<=0;
          if(length==0 || length>4096 || opcode>10 || source_a[11:0]!=0 ||
             ((opcode<2 || opcode==8 || opcode==9) && source_b[11:0]!=0) ||
             (opcode==9 && source_c[11:0]!=0)) state<=FAULTED;
          else state<=READ_REQUEST;
        end
        READ_REQUEST: if(read_ready) state<=READ_RESPONSE;
        READ_RESPONSE: if(read_response_valid) begin
          if(read_status!=0) state<=FAULTED;
          else begin
            operands[operand]<=read_data;
            if(operand==0 && uses_b) begin operand<=1; state<=READ_REQUEST; end
            else if(operand==1 && uses_c) begin operand<=2; state<=READ_REQUEST; end
            else begin lane<=0; state<=FEED; end
          end
        end
        FEED: if(vi_ready) begin
          fed<=fed+1;
          if(fed==count-1) state<=WAIT_COMMIT;
          else if(lane==7) begin offset<=offset+32; operand<=0; state<=READ_REQUEST; end
          else lane<=lane+1;
        end
        WAIT_COMMIT: if((vector_finished || vdone) && (writer_finished || wdone)) state<=COMPLETE;
        COMPLETE: if(completion_ready) state<=IDLE;
        FAULTED: state<=FAULTED;
        default: state<=FAULTED;
      endcase
      if(vc_error || wc_error || vfault || wfault) state<=FAULTED;
    end
  end
endmodule
