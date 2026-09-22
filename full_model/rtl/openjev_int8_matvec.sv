`timescale 1ns/1ps

// Row-major signed INT8 matrix-vector engine. Host pads each vector/row to
// LANES bytes; bytes past columns are ignored. Results are raw INT32 sums.
// Activations are loaded once per command and reused for every output row.
module openjev_int8_matvec #(
  parameter int LANES = 32,
  parameter int MAX_COLUMNS = 4096
) (
  input logic clk, rst_n,
  input logic command_valid,
  output logic command_ready,
  input logic [31:0] columns, rows,
  output logic command_error,
  input logic activation_valid,
  output logic activation_ready,
  input logic [LANES*8-1:0] activation_data,
  input logic weight_valid,
  output logic weight_ready,
  input logic [LANES*8-1:0] weight_data,
  output logic result_valid,
  input logic result_ready,
  output logic signed [31:0] result_data,
  output logic [31:0] result_row,
  output logic result_last,
  output logic busy, done
);
  localparam int WORDS = (MAX_COLUMNS + LANES - 1) / LANES;
  localparam int TREE_LEAVES = 2 ** $clog2(LANES);
  typedef enum logic [3:0] {IDLE, LOAD, RECEIVE, MULTIPLY, REDUCE, ACCUMULATE, EMIT} state_t;
  state_t state;
  (* ram_style = "block" *) logic [LANES*8-1:0] activation_mem [0:WORDS-1];
  logic [LANES*8-1:0] activation_q, weight_q;
  logic signed [15:0] products [0:LANES-1];
  logic signed [31:0] tree [1:2*TREE_LEAVES-1];
  logic signed [31:0] partial_sum, accumulator;
  logic [31:0] column_count, row_count, word_count, load_word, word_index;
  integer lane;

  assign command_ready = rst_n && state == IDLE;
  assign activation_ready = rst_n && state == LOAD;
  assign weight_ready = rst_n && state == RECEIVE;
  assign result_valid = rst_n && state == EMIT;
  assign result_last = result_valid && result_row == row_count - 1;
  assign busy = state != IDLE;

  // Balanced reduction avoids a 32-adder serial critical path.
  always_comb begin
    for (integer i = 0; i < TREE_LEAVES; i = i + 1) begin
      if (i < LANES) tree[TREE_LEAVES+i] = {{16{products[i][15]}}, products[i]};
      else tree[TREE_LEAVES+i] = '0;
    end
    for (integer i = TREE_LEAVES-1; i > 0; i = i - 1)
      tree[i] = tree[2*i] + tree[2*i+1];
  end

  // Synchronous activation read supports block-RAM inference.
  always_ff @(posedge clk) begin
    if (activation_valid && activation_ready)
      activation_mem[load_word] <= activation_data;
    if (weight_valid && weight_ready)
      activation_q <= activation_mem[word_index];
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= IDLE;
      command_error <= 0;
      done <= 0;
      result_row <= 0;
      result_data <= 0;
      column_count <= 0;
      row_count <= 0;
      word_count <= 0;
      load_word <= 0;
      word_index <= 0;
      accumulator <= 0;
      partial_sum <= 0;
      weight_q <= 0;
      for (lane = 0; lane < LANES; lane = lane + 1) products[lane] <= 0;
    end else begin
      done <= 0;
      command_error <= 0;
      case (state)
        IDLE: if (command_valid) begin
          if (columns == 0 || columns > MAX_COLUMNS || rows == 0)
            command_error <= 1;
          else begin
            column_count <= columns;
            row_count <= rows;
            word_count <= (columns + LANES - 1) / LANES;
            load_word <= 0;
            word_index <= 0;
            result_row <= 0;
            accumulator <= 0;
            state <= LOAD;
          end
        end
        LOAD: if (activation_valid) begin
          if (load_word == word_count - 1) state <= RECEIVE;
          else load_word <= load_word + 1;
        end
        RECEIVE: if (weight_valid) begin
          weight_q <= weight_data;
          state <= MULTIPLY;
        end
        MULTIPLY: begin
          for (lane = 0; lane < LANES; lane = lane + 1) begin
            if (word_index * LANES + lane < column_count)
              products[lane] <= $signed(activation_q[lane*8 +: 8]) * $signed(weight_q[lane*8 +: 8]);
            else products[lane] <= 0;
          end
          state <= REDUCE;
        end
        REDUCE: begin
          partial_sum <= tree[1];
          state <= ACCUMULATE;
        end
        ACCUMULATE: begin
          accumulator <= accumulator + partial_sum;
          if (word_index == word_count - 1) begin
            result_data <= accumulator + partial_sum;
            state <= EMIT;
          end else begin
            word_index <= word_index + 1;
            state <= RECEIVE;
          end
        end
        EMIT: if (result_ready) begin
          if (result_last) begin
            done <= 1;
            state <= IDLE;
          end else begin
            result_row <= result_row + 1;
            word_index <= 0;
            accumulator <= 0;
            state <= RECEIVE;
          end
        end
        default: state <= IDLE;
      endcase
    end
  end
endmodule
