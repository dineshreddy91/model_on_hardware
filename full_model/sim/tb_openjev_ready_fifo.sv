`timescale 1ns/1ps
module tb_openjev_ready_fifo;
  reg clk=0,rst_n=0,s_valid=0,m_ready=0;
  always #5 clk=~clk;
  reg [288:0] s_data=0;
  wire s_ready,m_valid;
  wire [288:0] m_data;
  reg [288:0] expected[0:4095],held;
  integer sent=0,received=0,cycles=0;
  reg stalled=0;
  openjev_ready_fifo dut(.*);
  function [288:0] payload(input integer n);
    payload={1'(n%7==0),32'(n*71),256'(n*1337+123)};
  endfunction
  always @(posedge clk)if(rst_n)begin
    if(stalled&&(!m_valid||m_data!==held))$fatal(1,"FIFO changed under stall");
    if(m_valid&&m_ready)begin
      if(received>=sent||m_data!==expected[received])$fatal(1,"FIFO loss/order/payload");
      received=received+1;
    end
    if(s_valid&&s_ready)begin expected[sent]=s_data;sent=sent+1;end
    stalled=m_valid&&!m_ready;held=m_data;
  end
  initial begin
    repeat(3)@(negedge clk);rst_n=1;
    for(cycles=0;cycles<3000;cycles=cycles+1)begin
      s_valid=cycles%5!=0;s_data=payload(sent);
      m_ready=cycles>20&&cycles%7!=0&&cycles%11!=0;
      @(negedge clk);
    end
    s_valid=0;m_ready=1;
    repeat(5)@(negedge clk);
    if(sent!=received||m_valid)$fatal(1,"FIFO failed drain");
    s_valid=1;m_ready=0;s_data=payload(sent);@(negedge clk);
    s_data=payload(sent);@(negedge clk);
    if(s_ready)$fatal(1,"FIFO failed full backpressure");
    rst_n=0;s_valid=0;stalled=0;@(negedge clk);
    if(m_valid||s_ready)$fatal(1,"FIFO reset handshake");
    sent=0;received=0;rst_n=1;m_ready=1;
    for(cycles=0;cycles<20;cycles=cycles+1)begin s_valid=1;s_data=payload(sent);@(negedge clk);end
    s_valid=0;repeat(4)@(negedge clk);
    if(sent!=received||m_valid)$fatal(1,"FIFO reset recovery");
    $display("PASS HBM write FIFO: ordering, payload/strobes/last, backpressure, full, simultaneous push/pop, reset");$finish;
  end
endmodule
