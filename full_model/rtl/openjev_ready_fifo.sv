`timescale 1ns/1ps
// Two-slot circular buffer: downstream READY only advances a pointer/count.
// Payload registers are written only on the upstream handshake.
module openjev_ready_fifo #(parameter integer WIDTH=289)(
  input wire clk,rst_n,s_valid,
  output wire s_ready,
  input wire [WIDTH-1:0] s_data,
  output wire m_valid,
  input wire m_ready,
  output wire [WIDTH-1:0] m_data
);
  reg [WIDTH-1:0] slot0,slot1;
  reg read_pointer,write_pointer;
  reg [1:0] count;
  assign s_ready=rst_n&&count!=2;
  assign m_valid=rst_n&&count!=0;
  assign m_data=read_pointer?slot1:slot0;
  wire push=s_valid&&s_ready;
  wire pop=m_valid&&m_ready;
  always @(posedge clk)begin
    if(!rst_n)begin read_pointer<=0;write_pointer<=0;count<=0;end
    else begin
      if(push)begin
        if(write_pointer)slot1<=s_data;else slot0<=s_data;
        write_pointer<=!write_pointer;
      end
      if(pop)read_pointer<=!read_pointer;
      case({push,pop})
        2'b10:count<=count+1;
        2'b01:count<=count-1;
        default:count<=count;
      endcase
    end
  end
endmodule
