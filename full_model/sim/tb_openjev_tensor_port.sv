`timescale 1ns/1ps
module tb_openjev_tensor_port;
  reg clk=0,rst_n=0,request_valid=0,request_write=0,response_ready=0;
  always #5 clk=~clk;
  wire request_ready,response_valid,response_error,fault;
  wire [3:0] fault_code;
  wire [31:0] response_data;
  reg [31:0] base_address=32'h02000000,bank_extent=4096,logical_bytes=131072,byte_offset=0,write_data=0;
  reg [2:0] element_bytes=4;
  wire [63:0] araddr,awaddr,wstrb;
  wire [7:0] arlen,awlen;
  wire [2:0] arsize,awsize;
  wire [1:0] arburst,awburst;
  wire [15:0] arid,awid;
  wire arvalid,rready,awvalid,wvalid,wlast,bready;
  reg arready=0,awready=0,wready=0,rvalid=0,bvalid=0,rlast=1;
  reg [15:0] rid=0,bid=0;
  reg [1:0] rresp=0,bresp=0;
  reg [511:0] rdata=0;
  wire [511:0] wdata;
  reg [7:0] memory[0:131071];
  reg have_aw=0,have_w=0,freeze_bus=0;
  reg [63:0] saved_addr,saved_strobe;
  reg [511:0] saved_data;
  integer cycle=0,transactions=0,index,i,j,b,size,tests=0,previous_transactions;
  reg [31:0] expected;
  reg [1023:0] descriptor,root_descriptor;
  wire [31:0] element_index=element_bytes==4 ? byte_offset>>2 : element_bytes==2 ? byte_offset>>1 : byte_offset;
  always @* begin
    root_descriptor=0;
    root_descriptor[0+:32]=1;root_descriptor[192+:32]=1;
    root_descriptor[32+:32]=element_bytes==4 ? 3 : element_bytes==2 ? 1 : element_bytes==1 ? 0 : 4;
    root_descriptor[64+:32]=2;root_descriptor[96+:32]=1;
    root_descriptor[128+:32]=base_address;root_descriptor[160+:32]=logical_bytes;
    root_descriptor[256+:32]=logical_bytes/(element_bytes==0 ? 1 : element_bytes);
    root_descriptor[384+:32]=(byte_offset&(element_bytes-1))!=0 ? 3 : element_bytes;
    root_descriptor[512+:32]=bank_extent;descriptor=root_descriptor;
  end
  reg run_enable=0,table_valid=0;
  wire table_ready;
  reg [31:0] tensor_count=2,table_index=1;
  reg [1023:0] table_data=0;
  wire [31:0] request_tensor=1,request_index=element_index;
  openjev_tensor_port #(.MAX_TENSORS(8),.WATCHDOG_CYCLES(80)) dut(.*);
  task configure;
    begin
      run_enable=0;@(negedge clk);
      table_data=root_descriptor;table_valid=1;
      @(negedge clk);table_valid=0;run_enable=1;@(negedge clk);
      if(table_ready) $fatal(1,"configuration not locked during run");
    end
  endtask
  function integer decode;
    input [63:0] address;
    reg [63:0] relative;
    integer bank,local_byte;
    begin
      relative=address-64'h1000000000;
      bank=(relative>>29)&31;
      local_byte=(relative&64'h1fffffff)-32'h02000000;
      if(address<64'h1000000000 || relative>=64'h400000000 || local_byte<0 || local_byte+64>4096)
        $fatal(1,"physical address outside allocation: %h",address);
      decode=bank*4096+local_byte;
    end
  endfunction
  always @(posedge clk) begin
    if(!rst_n) begin
      cycle<=0;arready<=0;awready<=0;wready<=0;rvalid<=0;bvalid<=0;have_aw<=0;have_w<=0;
    end else begin
      cycle<=cycle+1;
      arready<=!freeze_bus && !rvalid && cycle%3!=0;
      awready<=!freeze_bus && !have_aw && !bvalid && cycle%5==0;
      wready<=!freeze_bus && !have_w && !bvalid && cycle%3==0;
      if(arvalid&&arready) begin
        if(arlen!=0||arsize!=6||arburst!=1||arid!=0||araddr[5:0]!=0) $fatal(1,"AR shape");
        index=decode(araddr);
        for(i=0;i<64;i=i+1) rdata[i*8+:8]<=memory[index+i];
        rvalid<=1;transactions<=transactions+1;
      end else if(rvalid&&rready) rvalid<=0;
      if(awvalid&&awready) begin
        if(awlen!=0||awsize!=6||awburst!=1||awid!=0||awaddr[5:0]!=0) $fatal(1,"AW shape");
        saved_addr<=awaddr;have_aw<=1;
      end
      if(wvalid&&wready) begin
        if(!wlast) $fatal(1,"missing WLAST");
        saved_data<=wdata;saved_strobe<=wstrb;have_w<=1;
      end
      if(have_aw&&have_w&&!bvalid) begin
        index=decode(saved_addr);
        for(i=0;i<64;i=i+1) if(saved_strobe[i]) memory[index+i]<=saved_data[i*8+:8];
        bvalid<=1;have_aw<=0;have_w<=0;transactions<=transactions+1;
      end else if(bvalid&&bready) bvalid<=0;
    end
  end
  task access;
    input write_flag;
    input [31:0] offset;
    input [2:0] width;
    input [31:0] data;
    input bad;
    integer deadline;
    reg [31:0] captured;
    begin
      @(negedge clk);
      if(!request_ready) $fatal(1,"request not ready");
      request_write=write_flag;byte_offset=offset;element_bytes=width;write_data=data;
      configure;request_valid=1;
      @(negedge clk);request_valid=0;
      deadline=0;
      while(!response_valid) begin
        @(negedge clk);deadline=deadline+1;
        if(fault||deadline>300) $fatal(1,"unexpected timeout/fault");
      end
      if(response_error!=bad) $fatal(1,"response error mismatch");
      captured=response_data;
      if(!bad&&!write_flag&&response_data!==data) $fatal(1,"read mismatch offset=%h got=%h expected=%h",offset,response_data,data);
      repeat(3) begin @(negedge clk);if(!response_valid||response_data!==captured) $fatal(1,"response stall");end
      response_ready=1;@(negedge clk);response_ready=0;tests=tests+1;
    end
  endtask
  task reset;
    begin rst_n=0;request_valid=0;repeat(3) @(negedge clk);rst_n=1;@(negedge clk);configure;end
  endtask
  initial begin
    for(j=0;j<131072;j=j+1) memory[j]=8'ha5;
    reset;
    for(b=0;b<32;b=b+1) begin
      for(size=1;size<=4;size=size*2) begin
        expected=(32'h12345678+b)&(32'hffffffff>>(32-8*size));
        access(1,b*256+64-size,size,expected,0);
        access(0,b*256+64-size,size,expected,0);
        // Bytes immediately outside the strobe must survive.
        access(0,b*256+64-size-1,1,32'ha5,0);
        access(0,b*256+64,1,32'ha5,0);
      end
    end
    access(1,8192+252,4,32'hdeadbeef,0);
    access(0,8192+252,4,32'hdeadbeef,0);
    previous_transactions=transactions;
    access(1,131072,4,0,1);access(1,1,4,0,1);access(1,0,3,0,1);
    base_address=0;access(1,0,4,0,1);base_address=32'h02000001;access(0,0,4,0,1);
    base_address=32'h1ffff000;bank_extent=8192;access(0,0,4,0,1);
    base_address=32'h02000000;bank_extent=256;access(0,8192,4,0,1);bank_extent=4096;
    if(transactions!=previous_transactions) $fatal(1,"invalid request reached AXI");
    freeze_bus=1;@(negedge clk);request_valid=1;request_write=0;byte_offset=0;element_bytes=4;
    @(negedge clk);request_valid=0;repeat(180) @(negedge clk);
    if(!fault||fault_code!=4||!response_valid||!response_error) $fatal(1,"watchdog");
    freeze_bus=0;reset;rresp=2;
    request_valid=1;@(negedge clk);request_valid=0;repeat(100) @(negedge clk);
    if(!fault||fault_code!=1) $fatal(1,"read error");
    rresp=0;reset;
    if(fault||!request_ready) $fatal(1,"reset");
    $display("PASS loaded tensor-ID table through AXI HBM: %0d accesses, 32 banks, strobes, AW/W stalls, bounds, protection, timeout, read error",tests);
    $finish;
  end
  initial begin #1000000;$fatal(1,"testbench timeout");end
endmodule
