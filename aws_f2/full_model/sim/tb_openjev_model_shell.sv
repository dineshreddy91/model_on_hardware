`timescale 1ns/1ps
module tb_openjev_model_shell;
  reg clk=0,rst_n=0;
  always #5 clk=~clk;
  reg program_valid=0,metadata_valid=0,tensor_valid=0,start=0;
  wire program_ready,metadata_ready,tensor_ready,active,done,fault;
  wire [3:0] fault_code;
  wire [63:0] cycles;
  wire [31:0] instructions_retired;
  reg [31:0] program_index=0,metadata_index=0,tensor_index=0,program_length=0,tensor_count=0;
  reg [511:0] program_data=0;
  reg [255:0] metadata_data=0;
  reg [1023:0] tensor_data=0;
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

  reg [7:0] memory[0:8388607];
  reg [511:0] programs[0:63];
  reg [255:0] metadata[0:63];
  reg [1023:0] tensors[0:63];
  reg have_aw=0,have_w=0,freeze_bus=0;
  reg [63:0] saved_addr,saved_strobe;
  reg [511:0] saved_data;
  integer cycle=0,transactions=0,index,i,j,fd,outfd,n,address,deadline;
  integer tracefd,trace_id,trace_count,trace_width,trace_base,trace_offset,trace_addr,trace_i,trace_b,trace_dst;
  reg [31:0] trace_word;
  string directory,path;
  always @(posedge clk) if(dut.core.completion_valid&&!dut.core.completion_error) begin
    for(trace_dst=0;trace_dst<2;trace_dst=trace_dst+1) begin
      trace_id=programs[dut.core.completion_tag][64+trace_dst*32+:32];
      if(trace_id<tensor_count) begin
        trace_width=tensors[trace_id][32+:32]==0 ? 1 : tensors[trace_id][32+:32]==1 ? 2 : 4;
        trace_count=tensors[trace_id][160+:32]/trace_width;trace_base=tensors[trace_id][128+:32];
        for(trace_i=0;trace_i<trace_count;trace_i=trace_i+1) begin
          trace_word=0;
          for(trace_b=0;trace_b<trace_width;trace_b=trace_b+1) begin
            trace_offset=trace_i*trace_width+trace_b;
            trace_addr=decode(64'h1000000000+((64'(trace_offset>>8)%32)<<29)+trace_base+(trace_offset>>13)*256+(trace_offset%256));
            trace_word[trace_b*8+:8]=memory[trace_addr];
          end
          $fwrite(tracefd,"%0d %0d %0d %h\n",dut.core.completion_tag,trace_id,trace_i,trace_word);
        end
      end
    end
  end
  axi_bus_t bus();
  cfg_bus_t cfg();
  cl_dram_dma_axi_mstr dut(clk,rst_n,1'b1,bus,cfg);
  assign active=dut.active;assign done=dut.core_done;assign fault=dut.core_fault||dut.configuration_error;
  assign fault_code=dut.core_fault_code;assign cycles=dut.cycles;assign instructions_retired=dut.retired;
  assign program_ready=dut.pr;assign metadata_ready=dut.mr;assign tensor_ready=dut.tr;
  assign araddr=bus.araddr;
  assign arlen=bus.arlen;
  assign arsize=bus.arsize;
  assign arburst=bus.arburst;
  assign arid=bus.arid;
  assign arvalid=bus.arvalid;
  assign rready=bus.rready;
  assign awaddr=bus.awaddr;
  assign awlen=bus.awlen;
  assign awsize=bus.awsize;
  assign awburst=bus.awburst;
  assign awid=bus.awid;
  assign awvalid=bus.awvalid;
  assign wdata=bus.wdata;
  assign wstrb=bus.wstrb;
  assign wlast=bus.wlast;
  assign wvalid=bus.wvalid;
  assign bready=bus.bready;
  assign bus.arready=arready;
  assign bus.rdata=rdata;
  assign bus.rresp=rresp;
  assign bus.rid=rid;
  assign bus.rlast=rlast;
  assign bus.rvalid=rvalid;
  assign bus.awready=awready;
  assign bus.wready=wready;
  assign bus.bresp=bresp;
  assign bus.bid=bid;
  assign bus.bvalid=bvalid;
  function integer decode(input [63:0] addr);
    reg [63:0] relative;
    integer bank,local_byte;
    begin
      relative=addr-64'h1000000000;bank=(relative>>29)&31;local_byte=relative&64'h1fffffff;
      if(local_byte>=32'h02000000) local_byte=local_byte-32'h02000000+65536;
      if(addr<64'h1000000000||relative>=64'h400000000||local_byte<0||local_byte+64>262144) $fatal(1,"AXI bounds");
      decode=bank*262144+local_byte;
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

  task automatic write_reg(input int addr,input logic [31:0] data);
    @(negedge clk);cfg.addr=addr;cfg.wdata=data;cfg.wr=1;
    @(negedge clk);cfg.wr=0;
    wait(cfg.ack);@(negedge clk);wait(!cfg.ack);repeat(2) @(negedge clk);
  endtask
  initial begin
    cfg.wr=0;cfg.rd=0;cfg.addr=0;cfg.wdata=0;cfg.user=0;
    if(!$value$plusargs("directory=%s",directory)) $fatal(1,"directory");
    path={directory,"/control.txt"};fd=$fopen(path,"r");if(!fd) $fatal(1,"control");
    n=$fscanf(fd,"%d %d\n",program_length,tensor_count);if(n!=2) $fatal(1,"counts");
    $readmemh({directory,"/program.mem"},programs,0,program_length-1);
    $readmemh({directory,"/kernel_metadata.mem"},metadata,0,program_length-1);
    $readmemh({directory,"/tensors.mem"},tensors,0,tensor_count-1);
    $readmemh({directory,"/memory.mem"},memory);
    tracefd=$fopen({directory,"/trace.txt"},"w");
    repeat(3) @(negedge clk);rst_n=1;@(negedge clk);
    write_reg(8,program_length);write_reg(12,tensor_count);
    for(j=0;j<tensor_count;j=j+1) begin
      write_reg(16,j);
      for(int word=0;word<32;word++) write_reg(36,tensors[j][word*32+:32]);
      write_reg(40,1);
    end
    for(j=0;j<program_length;j=j+1) begin
      write_reg(16,j);
      for(int word=0;word<16;word++) write_reg(20,programs[j][word*32+:32]);
      write_reg(24,1);
      for(int word=0;word<8;word++) write_reg(28,metadata[j][word*32+:32]);
      write_reg(32,1);
    end
    for(integer run=0;run<2;run=run+1) begin
    repeat(3) @(negedge clk);write_reg(0,1);deadline=0;
    while(!done) begin
      @(negedge clk);deadline=deadline+1;
      if(fault||deadline>5000000) $fatal(1,"core fault %0d pc=%0d state=%0d",fault_code,dut.core.sequencer.pc,dut.core.dispatch.state);
      if(tensor_ready||metadata_ready||program_ready) $fatal(1,"configuration unlocked during graph");
    end
    if(instructions_retired!=program_length-1||rvalid||bvalid||have_aw||have_w) $fatal(1,"early graph completion");
    end
    path={directory,"/results.txt"};outfd=$fopen(path,"w");
    for(j=0;j<6;j=j+1) begin
      n=$fscanf(fd,"%d\n",address);if(n!=1) $fatal(1,"output address");
      $fwrite(outfd,"%h\n",{memory[address+3],memory[address+2],memory[address+1],memory[address]});
    end
    $fclose(fd);$fclose(outfd);$fclose(tracefd);
    write_reg(20,32'h1234);write_reg(24,1);
    if(!dut.configuration_error||active) $fatal(1,"partial program record accepted");
    $display("PASS host register framing, partial-record rejection, integrated program -> dispatch -> tensor/weight AXI -> committed outputs: %0d instructions, %0d cycles (simulation only)",instructions_retired,cycles);$finish;
  end
endmodule
