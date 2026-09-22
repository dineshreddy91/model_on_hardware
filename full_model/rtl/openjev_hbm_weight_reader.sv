`timescale 1ns/1ps

// Reads contiguous INT8 tensor bytes from the 32-bank striped HBM layout.
// One outstanding 32-byte read; external routing selects the bank using bank.
// All rows must be 32-byte aligned; no implicit padding is present in HBM.
// The shell adapter must return exactly one response per accepted request.
module openjev_hbm_weight_reader (
  input logic clk, rst_n,
  input logic command_valid,
  output logic command_ready,
  input logic [28:0] base_address,
  input logic [31:0] byte_count,
  output logic command_error,
  output logic request_valid,
  input logic request_ready,
  output logic [4:0] request_bank,
  output logic [28:0] request_address,
  input logic response_valid,
  output logic response_ready,
  input logic [255:0] response_data,
  input logic [1:0] response_status,
  output logic weight_valid,
  input logic weight_ready,
  output logic [255:0] weight_data,
  output logic weight_last,
  output logic done,
  output logic fault
);
  typedef enum logic [2:0] {IDLE, REQUEST, RESPONSE, OUTPUT_WORD, FAULTED} state_t;
  state_t state;
  logic [28:0] base;
  logic [31:0] total_bytes, offset;
  logic [32:0] allocation_end;
  // Each complete 8192-byte stripe consumes 256 bytes in every bank.
  // Conservatively reserve the same rounded allocation in every bank.
  assign allocation_end = {4'b0, base_address} +
      ((({1'b0, byte_count} + 33'd8191) >> 13) << 8);
  assign command_ready = rst_n && state == IDLE;
  assign request_valid = rst_n && state == REQUEST;
  assign request_bank = offset[12:8];
  assign request_address = base + {2'b0, offset[31:13], offset[7:0]};
  assign response_ready = rst_n && state == RESPONSE;
  assign weight_valid = rst_n && state == OUTPUT_WORD;
  assign weight_last = weight_valid && offset == total_bytes - 32;
  assign fault = state == FAULTED;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= IDLE;
      base <= 0;
      total_bytes <= 0;
      offset <= 0;
      weight_data <= 0;
      done <= 0;
      command_error <= 0;
    end else begin
      done <= 0;
      command_error <= 0;
      case (state)
        IDLE: if (command_valid) begin
          if (byte_count == 0 || byte_count[4:0] != 0 ||
              base_address[11:0] != 0 || allocation_end > 33'h020000000)
            command_error <= 1;
          else begin
            base <= base_address;
            total_bytes <= byte_count;
            offset <= 0;
            state <= REQUEST;
          end
        end
        REQUEST: if (request_ready) state <= RESPONSE;
        RESPONSE: if (response_valid) begin
          if (response_status != 0) state <= FAULTED;
          else begin
            weight_data <= response_data;
            state <= OUTPUT_WORD;
          end
        end
        OUTPUT_WORD: if (weight_ready) begin
          if (weight_last) begin
            done <= 1;
            state <= IDLE;
          end else begin
            offset <= offset + 32;
            state <= REQUEST;
          end
        end
        // Reset must also drain/reset the external memory adapter before reuse.
        FAULTED: state <= FAULTED;
        default: state <= FAULTED;
      endcase
    end
  end
endmodule
