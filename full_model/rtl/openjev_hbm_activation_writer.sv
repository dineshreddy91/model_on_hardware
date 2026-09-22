`timescale 1ns/1ps

// Writes 32-byte activation words into the existing 256-byte/32-bank layout.
// AW and W progress independently. Completion requires a successful B response.
// On fault, reset this unit AND the downstream AXI adapter before reuse.
module openjev_hbm_activation_writer (
  input logic clk, rst_n,
  input logic command_valid,
  output logic command_ready, command_error,
  input logic [28:0] base_address,
  input logic [31:0] byte_count,
  input logic input_valid,
  output logic input_ready,
  input logic [255:0] input_data,
  input logic input_last,
  output logic [63:0] awaddr,
  output logic [7:0] awlen,
  output logic [2:0] awsize,
  output logic [1:0] awburst,
  output logic awvalid,
  input logic awready,
  output logic [511:0] wdata,
  output logic [63:0] wstrb,
  output logic wlast, wvalid,
  input logic wready,
  input logic bvalid,
  output logic bready,
  input logic [1:0] bresp,
  input logic [15:0] bid,
  output logic done, fault,
  output logic [31:0] committed_bytes
);
  typedef enum logic [2:0] {IDLE, COLLECT, SEND, RESPONSE, FAULTED} state_t;
  state_t state;
  logic [28:0] base, local_address;
  logic [31:0] count, offset;
  logic [255:0] payload;
  logic aw_pending, w_pending;
  logic [32:0] allocation_end;

  assign allocation_end = {4'b0,base_address} +
      ((({1'b0,byte_count} + 33'd8191) >> 13) << 8);
  assign command_ready = rst_n && state == IDLE;
  assign input_ready = rst_n && state == COLLECT;
  assign local_address = base + {2'b0,offset[31:13],offset[7:0]};
  assign awaddr = 64'h1000000000 +
      {30'b0,offset[12:8],local_address[28:6],6'b0};
  assign awlen = 0;
  assign awsize = 6;
  assign awburst = 1;
  assign awvalid = rst_n && state == SEND && aw_pending;
  assign wvalid = rst_n && state == SEND && w_pending;
  assign wdata = local_address[5] ? {payload,256'b0} : {256'b0,payload};
  assign wstrb = local_address[5] ? 64'hffffffff00000000 : 64'h00000000ffffffff;
  assign wlast = 1;
  assign bready = rst_n && state == RESPONSE;
  assign fault = state == FAULTED;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= IDLE;
      base <= 0; count <= 0; offset <= 0; payload <= 0;
      aw_pending <= 0; w_pending <= 0;
      committed_bytes <= 0; done <= 0; command_error <= 0;
    end else begin
      done <= 0;
      command_error <= 0;
      case (state)
        IDLE: if (command_valid) begin
          if (byte_count == 0 || byte_count[4:0] != 0 ||
              base_address[11:0] != 0 || allocation_end > 33'h020000000)
            command_error <= 1;
          else begin
            base <= base_address; count <= byte_count; offset <= 0;
            committed_bytes <= 0;
            state <= COLLECT;
          end
        end
        COLLECT: if (input_valid) begin
          if (input_last != (offset == count-32)) state <= FAULTED;
          else begin
            payload <= input_data;
            aw_pending <= 1; w_pending <= 1;
            state <= SEND;
          end
        end
        SEND: begin
          if (awready) aw_pending <= 0;
          if (wready) w_pending <= 0;
          if ((!aw_pending || awready) && (!w_pending || wready))
            state <= RESPONSE;
        end
        RESPONSE: if (bvalid) begin
          if (bresp != 0 || bid != 0) state <= FAULTED;
          else begin
            committed_bytes <= committed_bytes + 32;
            if (offset == count-32) begin
              done <= 1;
              state <= IDLE;
            end else begin
              offset <= offset + 32;
              state <= COLLECT;
            end
          end
        end
        FAULTED: state <= FAULTED;
        default: state <= FAULTED;
      endcase
    end
  end
endmodule
