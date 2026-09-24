`timescale 1ns/1ps
// Raw 1/2/4-byte access to striped tensors through the shell's AXI512 port.
// A write response is produced only after B succeeds. Reset the AXI fabric
// together with this unit after timeout/protocol faults. A one-line read buffer
// reuses all bytes in an AXI beat. Writes invalidate it conservatively. Assert
// cache_invalidate whenever an external writer can modify this address space;
// the integrated tensor port asserts it between graph executions.
module openjev_hbm_element #(
  parameter integer WATCHDOG_CYCLES=1000000
)(
  input wire clk,rst_n,request_valid,cache_invalidate,
  output wire request_ready,
  input wire request_write,
  input wire [31:0] base_address,bank_extent,logical_bytes,byte_offset,
  input wire [2:0] element_bytes,
  input wire [31:0] write_data,
  output wire response_valid,
  input wire response_ready,
  output reg [31:0] response_data,
  output reg response_error,
  output wire fault,
  output reg [3:0] fault_code,
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
  localparam IDLE=0,READ_ADDRESS=1,READ_DATA=2,WRITE_SEND=3,WRITE_RESPONSE=4,RESULT=5,FAILED=6,READ_CHECK=7;
  reg [2:0] state;
  reg cache_valid;
  reg [63:0] cache_address;
  reg [511:0] cache_data;
  reg [63:0] address_q;
  reg [5:0] lane;
  reg [2:0] size_q;
  reg [31:0] payload,cycles;
  reg aw_pending,w_pending;
  wire [32:0] local_offset={14'b0,byte_offset[31:13],8'b0}+{25'b0,byte_offset[7:0]};
  wire [32:0] local_address={1'b0,base_address}+local_offset;
  wire [32:0] local_end=local_offset+element_bytes;
  wire [32:0] allocation_end={1'b0,base_address}+{1'b0,bank_extent};
  wire [32:0] logical_end={1'b0,byte_offset}+element_bytes;
  wire valid_size=element_bytes==1 || element_bytes==2 || element_bytes==4;
  wire valid_alignment=(element_bytes==1) || (element_bytes==2 && byte_offset[0]==0) ||
                       (element_bytes==4 && byte_offset[1:0]==0);
  wire geometry_ok=valid_size && valid_alignment && base_address[11:0]==0 &&
      bank_extent!=0 && bank_extent[7:0]==0 && logical_bytes!=0 &&
      allocation_end<=33'h020000000 && logical_end<={1'b0,logical_bytes} &&
      local_end<={1'b0,bank_extent} && (!request_write || base_address>=32'h02000000);
  assign request_ready=rst_n && state==IDLE;
  assign response_valid=rst_n && state==RESULT;
  assign fault=state==FAILED;
  assign araddr=address_q; assign awaddr=address_q;
  assign arlen=0; assign awlen=0; assign arsize=6; assign awsize=6;
  assign arburst=1; assign awburst=1; assign arid=0; assign awid=0;
  assign arvalid=rst_n && state==READ_ADDRESS;
  assign rready=rst_n && state==READ_DATA;
  assign awvalid=rst_n && state==WRITE_SEND && aw_pending;
  assign wvalid=rst_n && state==WRITE_SEND && w_pending;
  assign wdata={480'b0,payload} << (lane*8);
  assign wstrb=((64'b1 << size_q)-1) << lane;
  assign wlast=1;
  assign bready=rst_n && state==WRITE_RESPONSE;
  task fail;
    input [3:0] code;
    begin state<=FAILED;fault_code<=code;response_error<=1;end
  endtask
  always @(posedge clk) begin
    if(!rst_n) begin
      cache_valid<=0;cache_address<=0;cache_data<=0;
      state<=IDLE;address_q<=0;lane<=0;size_q<=0;payload<=0;cycles<=0;
      aw_pending<=0;w_pending<=0;response_data<=0;response_error<=0;fault_code<=0;
    end else begin
      if(state!=IDLE && state!=RESULT && state!=FAILED) cycles<=cycles+1;
      if(state!=IDLE && state!=RESULT && state!=FAILED && cycles>=WATCHDOG_CYCLES-1) fail(4);
      else case(state)
        IDLE: if(request_valid) begin
          cycles<=0;response_data<=0;response_error<=0;
          if(!geometry_ok) begin response_error<=1;state<=RESULT;end
          else begin
            address_q<=64'h1000000000+({59'b0,byte_offset[12:8]}<<29)+
                       {31'b0,local_address[32:6],6'b0};
            lane<=local_address[5:0];size_q<=element_bytes;payload<=write_data;
            if(request_write) begin cache_valid<=0;aw_pending<=1;w_pending<=1;state<=WRITE_SEND;end
            else state<=READ_CHECK;
          end
        end
        READ_CHECK: begin
          if(cache_valid && !cache_invalidate && cache_address==address_q) begin
            case(size_q)
              1: response_data<={24'b0,cache_data[lane*8+:8]};
              2: response_data<={16'b0,cache_data[lane*8+:16]};
              default: response_data<=cache_data[lane*8+:32];
            endcase
            state<=RESULT;
          end else state<=READ_ADDRESS;
        end
        READ_ADDRESS: if(arready) state<=READ_DATA;
        READ_DATA: if(rvalid) begin
          if(rresp!=0 || rid!=0 || !rlast) fail(1);
          else begin
            cache_valid<=1;cache_address<=address_q;cache_data<=rdata;
            case(size_q)
              1: response_data<={24'b0,rdata[lane*8+:8]};
              2: response_data<={16'b0,rdata[lane*8+:16]};
              default: response_data<=rdata[lane*8+:32];
            endcase
            state<=RESULT;
          end
        end
        WRITE_SEND: begin
          if(awready) aw_pending<=0;
          if(wready) w_pending<=0;
          if((!aw_pending||awready)&&(!w_pending||wready)) state<=WRITE_RESPONSE;
        end
        WRITE_RESPONSE: if(bvalid) begin
          if(bresp!=0 || bid!=0) fail(2);
          else state<=RESULT;
        end
        RESULT: if(response_ready) state<=IDLE;
        FAILED: state<=FAILED;
        default: fail(3);
      endcase
      if(cache_invalidate) cache_valid<=0;
    end
  end
endmodule
