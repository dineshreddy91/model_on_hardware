`timescale 1ns/1ps
// In-order descriptor sequencer. Engines: vector=0, matvec=1, copy=2.
// Addresses are 4KiB-aligned bank-local bases in the 32-bank striped format.
// End-of-program is accepted only after the final engine completion is checked.
// A fault requires reset of this sequencer AND every attached engine/AXI path.
module openjev_command_scheduler #(
  parameter logic [2:0] ENABLED_ENGINES=3'b000,
  parameter logic [31:0] SCRATCH_BEGIN=32'h02000000,
  parameter logic [31:0] MEMORY_END=32'h20000000,
  parameter logic [31:0] WATCHDOG_CYCLES=32'd100000000
)(
  input logic clk,rst_n,command_valid,
  output logic command_ready,
  input logic [1:0] command_engine,
  input logic [3:0] command_opcode,
  input logic [15:0] command_tag,
  input logic command_last,
  input logic [28:0] command_a,command_b,command_c,command_dst,
  input logic [31:0] command_count,command_width,command_epsilon,
  output logic request_valid,
  input logic request_ready,
  output logic [1:0] request_engine,
  output logic [3:0] request_opcode,
  output logic [15:0] request_tag,
  output logic [28:0] request_a,request_b,request_c,request_dst,
  output logic [31:0] request_count,request_width,request_epsilon,
  input logic response_valid,
  output logic response_ready,
  input logic [1:0] response_engine,
  input logic [15:0] response_tag,
  input logic response_error,
  output logic completion_valid,
  input logic completion_ready,
  output logic [15:0] completion_tag,
  output logic completion_last,
  output logic [31:0] completed_commands,
  output logic fault,
  output logic [3:0] fault_code
);
  typedef enum logic [2:0] {IDLE,PREPARE,VALIDATE,DISPATCH,RUNNING,COMPLETE,FAULTED} state_t;
  state_t state;
  logic last_command,uses_b,uses_c;
  logic [31:0] elapsed;
  logic [63:0] bytes_a,bytes_b,bytes_c,bytes_dst;
  logic [63:0] extent_a,extent_b,extent_c,extent_dst;
  logic invalid_shape,invalid_range,invalid_overlap,unsupported;

  function automatic logic [63:0] extent(input logic [63:0] logical_bytes);
    extent=((logical_bytes+8191)>>13)<<8;
  endfunction
  function automatic logic bad_range(input logic [28:0] base,input logic [63:0] size);
    bad_range=base[11:0]!=0 || size==0 || ({35'b0,base}+size)>{32'b0,MEMORY_END};
  endfunction
  function automatic logic overlap(input logic [28:0] src,input logic [63:0] size);
    overlap=({35'b0,src}<({35'b0,request_dst}+extent_dst)) &&
            ({35'b0,request_dst}<({35'b0,src}+size));
  endfunction
  assign command_ready=rst_n && state==IDLE;
  assign request_valid=rst_n && state==DISPATCH;
  assign response_ready=rst_n && state==RUNNING;
  assign completion_valid=rst_n && state==COMPLETE;
  assign completion_tag=request_tag;
  assign completion_last=last_command;
  assign fault=state==FAULTED;
  always_comb begin
    uses_b=0; uses_c=0; invalid_shape=0;
    bytes_a={32'b0,request_count}<<2; bytes_b=bytes_a; bytes_c=bytes_a; bytes_dst=bytes_a;
    case(request_engine)
      0: begin
        uses_b=request_opcode<2 || request_opcode==8 || request_opcode==9;
        uses_c=request_opcode==9;
        invalid_shape=request_count==0 || request_count>4096 || request_opcode>10 ||
          (request_opcode>=8 && request_opcode<=9 &&
           (request_epsilon[31] || request_epsilon[30:0]==0 || request_epsilon[30:23]==255));
      end
      1: begin
        uses_b=1; bytes_a={32'b0,request_width};
        bytes_b={50'b0,request_count[13:0]}*{51'b0,request_width[12:0]};
        invalid_shape=request_opcode!=0 || request_count==0 || request_count>8192 ||
          request_width==0 || request_width>4096 || request_width[4:0]!=0;
      end
      2: begin
        bytes_a={32'b0,request_count}; bytes_dst=bytes_a;
        invalid_shape=request_opcode!=0 || request_count==0 || request_count[4:0]!=0;
      end
      default: invalid_shape=1;
    endcase
    unsupported=request_engine>2;
    if(request_engine<=2) unsupported=!ENABLED_ENGINES[request_engine];
    invalid_range=bad_range(request_a,extent_a) || bad_range(request_dst,extent_dst) ||
      {3'b0,request_dst}<SCRATCH_BEGIN || (uses_b && bad_range(request_b,extent_b)) ||
      (uses_c && bad_range(request_c,extent_c));
    invalid_overlap=overlap(request_a,extent_a) || (uses_b && overlap(request_b,extent_b)) ||
      (uses_c && overlap(request_c,extent_c));
  end
  always_ff @(posedge clk) begin
    if(!rst_n) begin
      extent_a<=0; extent_b<=0; extent_c<=0; extent_dst<=0;
      state<=IDLE; fault_code<=0; elapsed<=0; completed_commands<=0; last_command<=0;
      request_engine<=0; request_opcode<=0; request_tag<=0;
      request_a<=0; request_b<=0; request_c<=0; request_dst<=0;
      request_count<=0; request_width<=0; request_epsilon<=0;
    end else case(state)
      IDLE: if(command_valid) begin
        request_engine<=command_engine; request_opcode<=command_opcode; request_tag<=command_tag;
        request_a<=command_a; request_b<=command_b; request_c<=command_c; request_dst<=command_dst;
        request_count<=command_count; request_width<=command_width; request_epsilon<=command_epsilon;
        last_command<=command_last; elapsed<=0; state<=PREPARE;
      end
      PREPARE: begin
        extent_a<=extent(bytes_a); extent_b<=extent(bytes_b);
        extent_c<=extent(bytes_c); extent_dst<=extent(bytes_dst);
        state<=VALIDATE;
      end
      VALIDATE: begin
        if(unsupported) begin fault_code<=1; state<=FAULTED; end
        else if(invalid_shape) begin fault_code<=2; state<=FAULTED; end
        else if(invalid_range) begin fault_code<=3; state<=FAULTED; end
        else if(invalid_overlap) begin fault_code<=4; state<=FAULTED; end
        else state<=DISPATCH;
      end
      DISPATCH,RUNNING: begin
        if(WATCHDOG_CYCLES==0 || elapsed>=WATCHDOG_CYCLES-1) begin fault_code<=5; state<=FAULTED; end
        else begin
          elapsed<=elapsed+1;
          if(state==DISPATCH && request_ready) state<=RUNNING;
          if(state==RUNNING && response_valid) begin
            if(response_engine!=request_engine || response_tag!=request_tag) begin
              fault_code<=6; state<=FAULTED;
            end else if(response_error) begin fault_code<=7; state<=FAULTED; end
            else begin completed_commands<=completed_commands+1; state<=COMPLETE; end
          end
        end
      end
      COMPLETE: if(completion_ready) state<=IDLE;
      FAULTED: state<=FAULTED;
      default: begin fault_code<=8; state<=FAULTED; end
    endcase
  end
endmodule
