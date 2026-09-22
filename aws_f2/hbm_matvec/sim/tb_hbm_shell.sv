`timescale 1ns/1ps
module tb_hbm_shell;
  logic clk=0, rst_n=0;
  always #2 clk=~clk;
  axi_bus_t bus();
  cfg_bus_t cfg();
  cl_dram_dma_axi_mstr dut(clk,rst_n,1'b1,bus,cfg);
  int tick=0, count=0, delay_q=0;
  logic pending=0, inject_error=0;
  logic [63:0] address_q;
  int bank, offset, logical_byte;
  int signed expected, a, w;
  logic [31:0] value, word_value;
  function automatic byte weight(input int n);
    return byte'((n*17+n/1024*7+3)%256-128);
  endfunction
  function automatic byte activation(input int n);
    return byte'((n*73+19)%256-128);
  endfunction
  assign bus.arready = !pending && !bus.rvalid && tick%7 != 0;
  always @(posedge clk) begin
    tick <= tick+1;
    if (!rst_n) begin
      pending<=0;bus.rvalid<=0;bus.rdata<=0;bus.rresp<=0;bus.rlast<=1;bus.rid<=0;count<=0;
    end else begin
      if (bus.arvalid && bus.arready) begin
        if (bus.arlen != 0 || bus.arsize != 6 || bus.araddr[5:0] != 0)
          $fatal(1,"AXI alignment/size");
        address_q<=bus.araddr;pending<=1;delay_q<=tick%11+1;count<=count+1;
      end
      if (pending) begin
        if (delay_q != 0) delay_q<=delay_q-1;
        else begin
          bank=(address_q-64'h1000000000)>>29;
          offset=(address_q & 64'h1fffffff)-4096;
          if (bank<0 || bank>31 || offset<0) $fatal(1,"HBM address");
          for (int i=0;i<64;i++) begin
            logical_byte=(offset/256)*8192+bank*256+(offset%256)+i;
            bus.rdata[i*8+:8]<=weight(logical_byte);
          end
          bus.rresp<=inject_error ? 2 : 0;
          bus.rvalid<=1;pending<=0;
        end
      end
      if (bus.rvalid && bus.rready) bus.rvalid<=0;
    end
  end
  task automatic write_reg(input int addr,input logic [31:0] data);
    @(negedge clk);cfg.addr=addr;cfg.wdata=data;cfg.wr=1;
    @(negedge clk);cfg.wr=0;
    wait(cfg.ack);@(negedge clk);wait(!cfg.ack);repeat(2) @(negedge clk);
  endtask
  task automatic read_reg(input int addr,output logic [31:0] data);
    @(negedge clk);cfg.addr=addr;cfg.rd=1;
    @(negedge clk);cfg.rd=0;
    wait(cfg.ack);@(negedge clk);data=cfg.rdata;
    wait(!cfg.ack);repeat(2) @(negedge clk);
  endtask
  task automatic reset;
    @(negedge clk);rst_n=0;repeat(8) @(negedge clk);rst_n=1;repeat(8) @(negedge clk);
  endtask
  initial begin
    cfg.wr=0;cfg.rd=0;cfg.addr=0;cfg.wdata=0;cfg.user=0;
    bus.awready=0;bus.wready=0;bus.bvalid=0;bus.bresp=0;bus.bid=0;
    reset();read_reg(0,value);if(value!=32'h48424d31) $fatal(1,"magic");
    for (int run=0;run<2;run++) begin
      write_reg(8,1024);write_reg(12,16);write_reg(16,4096);write_reg(0,1);
      for(int i=0;i<256;i++) begin
        read_reg(4,value);while(!value[3]) read_reg(4,value);
        for(int j=0;j<4;j++) word_value[j*8+:8]=activation(i*4+j);
        write_reg(32,word_value);
      end
      read_reg(4,value);while(!value[1] && !value[2]) read_reg(4,value);
      if(value[2] || value[0]) $fatal(1,"status %x",value);
      read_reg(28,value);if(value!=16) $fatal(1,"result count");
      read_reg(24,value);if(value!=512) $fatal(1,"request count %d",value);
      for(int r=0;r<16;r++) begin
        expected=0;
        for(int c=0;c<1024;c++) begin
          a=activation(c);w=weight(r*1024+c);expected+=a*w;
        end
        write_reg(40,r);read_reg(44,value);
        if($signed(value)!=expected) $fatal(1,"row %d got %d expected %d",r,$signed(value),expected);
      end
    end
    // Invalid shape must be rejected without issuing AXI traffic.
    write_reg(8,33);write_reg(0,1);read_reg(4,value);
    if(!value[2] || value[1] || value[0]) $fatal(1,"invalid command not rejected");
    reset();inject_error=1;
    write_reg(8,32);write_reg(12,1);write_reg(16,4096);write_reg(0,1);
    repeat(100) @(negedge clk);read_reg(4,value);
    if(!value[2] || value[1]) $fatal(1,"AXI error not latched");
    $display("PASS HBM shell: repeated commands, all 32 banks, AXI stalls, 32 rows, invalid shape and AXI fault");$finish;
  end
  initial begin #2000000;$fatal(1,"watchdog");end
endmodule
