`timescale 1ns/1ps
// Real attention -> memory -> real recurrence. Memory only serves/stores words.
module tb_openjev_graph_chain;
  reg clk=0,rst_n=0,load_valid=0,start=0;
  always #5 clk=~clk;
  reg [31:0] load_index=0;
  reg [511:0] load_data=0;
  wire load_ready,dispatch_valid,dispatch_ready,done,fault;
  wire [3:0] fault_code;
  wire [511:0] dispatch_data;
  wire adone,ddone,afault,dfault,acr,dcr,ace,dce;
  wire arv,arr,apr,aov,aol,drv,drr,dpr,dov,dos,dol;
  reg apv=0,dpv=0;
  wire [1:0] art;
  wire [2:0] drt;
  wire [31:0] ari,aoi,aod,dri,doi,dod;
  reg [31:0] ard=0,drd=0;
  wire [3:0] afc,dfc;
  reg [31:0] q[0:3],k[0:3],v[0:3],intermediate[0:3];
  integer cycle=0,awrites=0,dwrites=0,swrites=0,fd;
  string result_path;
  wire selected_a=dispatch_data[7:0]==22;
  assign dispatch_ready=selected_a ? acr : dcr;
  assign arr=!apv && cycle%3!=0;
  assign drr=!dpv && cycle%3!=0;
  wire sink_ready=cycle%5!=0;
  openjev_graph_sequencer #(.MAX_INSTRUCTIONS(4),
    .CAPABILITIES((256'b1<<22)|(256'b1<<23)),.WATCHDOG_CYCLES(200000)) seq(
    .clk(clk),.rst_n(rst_n),.load_valid(load_valid),.load_ready(load_ready),
    .load_index(load_index),.load_data(load_data),.start(start),
    .program_length(32'd3),.tensor_count(32'd10),.dispatch_valid(dispatch_valid),
    .dispatch_ready(dispatch_ready),.dispatch_data(dispatch_data),
    .completion_valid(adone||ddone),.completion_tag(adone ? 32'd0 : 32'd1),
    .completion_error(afault||dfault),.done(done),.fault(fault),.fault_code(fault_code));
  openjev_attention #(.MAX_KEYS(2),.MAX_DIM(2)) attention(
    clk,rst_n,dispatch_valid&&selected_a,acr,ace,
    32'd2,32'd2,32'd2,32'd0,1'b0,1'b0,
    arv,arr,art,ari,apv,apr,ard,1'b0,aov,sink_ready,aoi,aod,aol,adone,afault,afc);
  openjev_gated_delta #(.MAX_KEY_DIM(2),.MAX_VALUE_DIM(2),.MAX_TOKENS(2)) delta(
    clk,rst_n,dispatch_valid&&!selected_a,dcr,dce,
    32'd2,32'd2,32'd2,1'b0,1'b0,
    drv,drr,drt,dri,dpv,dpr,drd,1'b0,dov,sink_ready,dos,doi,dod,dol,ddone,dfault,dfc);
  always @(posedge clk) begin
    if(rst_n) begin
      cycle<=cycle+1;
      if(afault||dfault||fault||ace||dce) $fatal(1,"chain fault");
      if(arv&&arr) begin
        if(ari>=4) $fatal(1,"attention read bounds");
        case(art)
          0: ard<=q[ari]; 1: ard<=k[ari]; 2: ard<=v[ari];
          default: $fatal(1,"unexpected mask read");
        endcase
        apv<=1;
      end else if(apv&&apr) apv<=0;
      if(aov&&sink_ready) begin
        if(aoi!=awrites) $fatal(1,"attention write order");
        intermediate[aoi]<=aod; awrites<=awrites+1;
        $fwrite(fd,"0 0 %0d %h\n",aoi,aod);
      end
      if(dispatch_valid&&!selected_a && awrites!=4) $fatal(1,"dependency dispatched too early");
      if(drv&&drr) begin
        if(dri>=4) $fatal(1,"delta read bounds");
        case(drt)
          0: drd<=intermediate[dri]; 1: drd<=k[dri]; 2: drd<=v[dri];
          4: drd<=32'hbe800000; // log decay -0.25
          5: drd<=32'h3f000000; // beta 0.5
          default: $fatal(1,"unexpected state read");
        endcase
        dpv<=1;
      end else if(dpv&&dpr) dpv<=0;
      if(dov&&sink_ready) begin
        if(dos) begin
          if(doi!=swrites) $fatal(1,"state write order");
          swrites<=swrites+1;
        end else begin
          if(doi!=dwrites) $fatal(1,"delta write order");
          dwrites<=dwrites+1;
        end
        $fwrite(fd,"1 %0d %0d %h\n",dos,doi,dod);
      end
    end
  end
  function [511:0] command;
    input [7:0] op; input [31:0] tag;
    reg [511:0] data; reg [31:0] check; integer i;
    begin
      data=0;data[7:0]=op;data[32+:32]=tag;
      for(i=2;i<10;i=i+1) data[i*32+:32]=32'hffffffff;
      if(op!=255) begin data[64+:32]=2+tag;data[128+:32]=tag;end
      check=32'h4f4a5031;
      for(i=0;i<15;i=i+1) check=check^data[i*32+:32];
      data[480+:32]=check;command=data;
    end
  endfunction
  task load;
    input [31:0] index;input [7:0] opcode;
    begin
      @(negedge clk);load_index=index;load_data=command(opcode,index);load_valid=1;
      @(negedge clk);load_valid=0;
    end
  endtask
  initial begin
    if(!$value$plusargs("results=%s",result_path)) $fatal(1,"results path");
    fd=$fopen(result_path,"w");if(!fd) $fatal(1,"results file");
    q[0]=32'h3f800000;q[1]=32'h00000000;q[2]=32'h00000000;q[3]=32'h3f800000;
    k[0]=32'h3f000000;k[1]=32'h3f800000;k[2]=32'hbf000000;k[3]=32'h3e800000;
    v[0]=32'h3e800000;v[1]=32'hbf000000;v[2]=32'h3f800000;v[3]=32'h3f000000;
    repeat(3) @(negedge clk);rst_n=1;
    load(0,22);load(1,23);load(2,255);
    @(negedge clk);start=1;@(negedge clk);start=0;
    wait(done);@(negedge clk);
    if(awrites!=4||dwrites!=4||swrites!=4) $fatal(1,"lost writes");
    $display("PASS graph chain: real attention -> stored tensor -> real gated delta, 12 committed values");
    $fclose(fd);$finish;
  end
  initial begin #3000000; $fatal(1,"chain timeout");end
endmodule
