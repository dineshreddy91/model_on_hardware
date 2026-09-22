`timescale 1ns/1ps
module tb_openjev_model_core;
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
  always @(posedge clk) if(dut.completion_valid&&!dut.completion_error) begin
    for(trace_dst=0;trace_dst<2;trace_dst=trace_dst+1) begin
      trace_id=programs[dut.completion_tag][64+trace_dst*32+:32];
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
          $fwrite(tracefd,"%0d %0d %0d %h\n",dut.completion_tag,trace_id,trace_i,trace_word);
        end
      end
    end
  end
  openjev_model_core #(.MAX_INSTRUCTIONS(64),.MAX_TENSORS(64)) dut(.*);
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

  initial begin
    if(!$value$plusargs("directory=%s",directory)) $fatal(1,"directory");
    path={directory,"/control.txt"};fd=$fopen(path,"r");if(!fd) $fatal(1,"control");
    n=$fscanf(fd,"%d %d\n",program_length,tensor_count);if(n!=2) $fatal(1,"counts");
    $readmemh({directory,"/program.mem"},programs,0,program_length-1);
    $readmemh({directory,"/kernel_metadata.mem"},metadata,0,program_length-1);
    $readmemh({directory,"/tensors.mem"},tensors,0,tensor_count-1);
    $readmemh({directory,"/memory.mem"},memory);
    tracefd=$fopen({directory,"/trace.txt"},"w");
    repeat(3) @(negedge clk);rst_n=1;@(negedge clk);
    for(j=0;j<tensor_count;j=j+1) begin
      tensor_index=j;tensor_data=tensors[j];tensor_valid=1;
      @(negedge clk);if(!tensor_ready) $fatal(1,"tensor load");
    end
    tensor_valid=0;
    for(j=0;j<program_length;j=j+1) begin
      program_index=j;program_data=programs[j];program_valid=1;
      metadata_index=j;metadata_data=metadata[j];metadata_valid=1;
      @(negedge clk);if(!program_ready||!metadata_ready) $fatal(1,"program load");
    end
    program_valid=0;metadata_valid=0;
    for(integer run=0;run<2;run=run+1) begin
    repeat(3) @(negedge clk);start=1;@(negedge clk);start=0;deadline=0;
    while(!done) begin
      @(negedge clk);deadline=deadline+1;
      if(fault||deadline>5000000) $fatal(1,"core fault %0d pc=%0d state=%0d",fault_code,dut.sequencer.pc,dut.dispatch.state);
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
    $display("PASS two consecutive integrated program executions -> dispatch -> tensor/weight AXI -> committed outputs: %0d instructions, %0d cycles (simulation only)",instructions_retired,cycles);$finish;
  end
endmodule
