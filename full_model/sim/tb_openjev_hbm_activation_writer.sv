`timescale 1ns/1ps
module tb_openjev_hbm_activation_writer;
  logic clk=0;
  always #2 clk=~clk;
  logic rst_n=0, command_valid=0, command_ready, command_error;
  logic [28:0] base_address=0;
  logic [31:0] byte_count=0;
  logic input_valid=0, input_ready, input_last=0;
  logic [255:0] input_data=0;
  logic [63:0] awaddr;
  logic [7:0] awlen;
  logic [2:0] awsize;
  logic [1:0] awburst;
  logic awvalid, awready=0;
  logic [511:0] wdata;
  logic [63:0] wstrb;
  logic wlast,wvalid,wready=0,bvalid=0,bready;
  logic [1:0] bresp=0;
  logic [15:0] bid=0;
  logic done,fault;
  logic [31:0] committed_bytes;
  integer checked=0;
  openjev_hbm_activation_writer dut(.*);
  task automatic tick;
    @(posedge clk); #1;
  endtask
  task automatic reset_dut;
    @(negedge clk);
    rst_n=0; command_valid=0; input_valid=0;
    awready=0; wready=0; bvalid=0; bresp=0; bid=0;
    tick();
    if (awvalid || wvalid || bready || input_ready || done || fault)
      $fatal(1,"Reset did not quiesce interface");
    @(negedge clk); rst_n=1;
    tick();
  endtask
  task automatic command(input logic [28:0] base, input logic [31:0] bytes);
    @(negedge clk); base_address=base; byte_count=bytes; command_valid=1;
    tick();
    @(negedge clk); command_valid=0;
  endtask
  task automatic word(input integer index, input integer words, input integer mode);
    logic [511:0] saved_data;
    logic [63:0] saved_address,saved_strobe,expected_address;
    logic [255:0] expected_data;
    integer local_offset;
    if (!input_ready) $fatal(1,"Not ready for activation");
    expected_data={8{32'h12340000+index}};
    @(negedge clk);
    input_data=expected_data; input_valid=1; input_last=(index==words-1);
    tick();
    @(negedge clk); input_valid=0; input_data='1;
    local_offset=(index/256)*256+(index%8)*32;
    expected_address=64'h1000000000+((64'(index/8)%32)<<29)+
        64'(base_address)+64'((local_offset/64)*64);
    if (awaddr !== expected_address || awlen!=0 || awsize!=6 || awburst!=1)
      $fatal(1,"Address/attributes mismatch at word %0d: %h != %h",index,awaddr,expected_address);
    if (wstrb !== ((index%2) ? 64'hffffffff00000000 : 64'h00000000ffffffff))
      $fatal(1,"Incorrect byte enables");
    if ((index%2 ? wdata[511:256] : wdata[255:0]) !== expected_data || !wlast)
      $fatal(1,"Incorrect payload");
    saved_data=wdata; saved_strobe=wstrb; saved_address=awaddr;
    repeat(3) begin
      tick();
      if (!awvalid || !wvalid || awaddr!==saved_address ||
          wdata!==saved_data || wstrb!==saved_strobe || done)
        $fatal(1,"Payload changed under stall");
    end
    @(negedge clk);
    awready=(mode!=1); wready=(mode!=0);
    tick();
    @(negedge clk); awready=0; wready=0;
    if (mode<2) begin
      repeat(3) begin
        tick();
        if (awvalid !== (mode==1) || wvalid !== (mode==0) || bready || done)
          $fatal(1,"AW/W channel independence failed");
      end
      @(negedge clk); awready=1; wready=1;
      tick();
      @(negedge clk); awready=0; wready=0;
    end
    repeat(4) begin
      tick();
      if (!bready || done || committed_bytes!=index*32)
        $fatal(1,"Completion before B response");
    end
    @(negedge clk); bvalid=1;
    tick();
    @(negedge clk); bvalid=0;
    if (bresp!=0 || bid!=0) begin
      if (!fault || done || committed_bytes!=index*32)
        $fatal(1,"Failed write was committed");
    end else begin
      if (fault || committed_bytes!=(index+1)*32 || done!=(index==words-1))
        $fatal(1,"Incorrect completion");
      checked=checked+1;
    end
  endtask
  initial begin
    reset_dut();
    command(29'h12000,320*32);
    for(integer i=0;i<320;i=i+1) word(i,320,i%3);
    tick();
    if (done || !command_ready) $fatal(1,"Done must pulse once");
    command(29'h1ffff000,32);
    word(0,1,2);
    tick();
    command(0,0); if (!command_error) $fatal(1,"Accepted zero count");
    command(0,33); if (!command_error) $fatal(1,"Accepted partial word");
    command(1,32); if (!command_error) $fatal(1,"Accepted unaligned base");
    command(29'h1ffff000,32'd131104);
    if (!command_error) $fatal(1,"Accepted bank overflow");
    command(0,64);
    @(negedge clk); input_valid=1; input_last=1;
    tick();
    if (!fault || awvalid || wvalid) $fatal(1,"Accepted early last");
    reset_dut();
    command(0,32);
    @(negedge clk); input_valid=1; input_last=0;
    tick();
    if (!fault || awvalid || wvalid) $fatal(1,"Accepted missing last");
    reset_dut();
    command(0,32); bresp=2; word(0,1,0);
    repeat(3) tick();
    if (!fault || command_ready) $fatal(1,"Fault was not sticky");
    reset_dut();
    command(0,32); bid=1; word(0,1,1);
    reset_dut();
    command(0,32); word(0,1,2);
    $display("PASS HBM activation writer: %0d committed words, all 32 banks, both halves, independent AW/W, delayed/error B, bounds and framing",checked);
    $finish;
  end
  initial begin #1000000; $fatal(1,"Simulation timed out"); end
endmodule
