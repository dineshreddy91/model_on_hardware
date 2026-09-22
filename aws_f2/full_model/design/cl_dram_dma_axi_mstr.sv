// Full-model graph control block for the existing F2 HBM shell.
module cl_dram_dma_axi_mstr (
  input logic aclk,aresetn,hbm_ready,
  axi_bus_t.slave cl_axi_mstr_bus,
  cfg_bus_t.slave axi_mstr_cfg_bus
);
  logic wr_q,rd_q;
  logic [7:0] addr_q;
  logic [31:0] data_q,index_q,program_length,tensor_count;
  logic start,active,core_done,core_fault,completed,configuration_error;
  logic [3:0] core_fault_code;
  logic [63:0] cycles;
  logic [31:0] retired;
  logic pv,mv,tv,pr,mr,tr;
  logic [31:0] pi,mi,ti;
  logic [511:0] program_shift;
  logic [255:0] metadata_shift;
  logic [1023:0] tensor_shift;
  logic [5:0] program_words,metadata_words,tensor_words;
  wire write_fire=wr_q&&!axi_mstr_cfg_bus.ack;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      wr_q <= 0; rd_q <= 0; addr_q <= 0; data_q <= 0;
      axi_mstr_cfg_bus.ack <= 0;
    end else begin
      wr_q <= axi_mstr_cfg_bus.wr || (wr_q && !axi_mstr_cfg_bus.ack);
      rd_q <= axi_mstr_cfg_bus.rd || (rd_q && !axi_mstr_cfg_bus.ack);
      if (axi_mstr_cfg_bus.wr || axi_mstr_cfg_bus.rd) begin
        addr_q <= axi_mstr_cfg_bus.addr[7:0];
        data_q <= axi_mstr_cfg_bus.wdata;
      end
      axi_mstr_cfg_bus.ack <= (wr_q || rd_q) && !axi_mstr_cfg_bus.ack;
    end
  end


  always_ff @(posedge aclk) begin
    case(addr_q)
      8'h00: axi_mstr_cfg_bus.rdata<=32'h4f4a4631;
      8'h04: axi_mstr_cfg_bus.rdata<={27'b0,hbm_ready,configuration_error,core_fault,completed,active};
      8'h08: axi_mstr_cfg_bus.rdata<=program_length;
      8'h0c: axi_mstr_cfg_bus.rdata<=tensor_count;
      8'h10: axi_mstr_cfg_bus.rdata<=index_q;
      8'h2c: axi_mstr_cfg_bus.rdata<=cycles[31:0];
      8'h30: axi_mstr_cfg_bus.rdata<=cycles[63:32];
      8'h34: axi_mstr_cfg_bus.rdata<=retired;
      8'h38: axi_mstr_cfg_bus.rdata<={28'b0,core_fault_code};
      8'h3c: axi_mstr_cfg_bus.rdata<=32'h00fffffe;
      8'h40: axi_mstr_cfg_bus.rdata<=1;
      8'h44: axi_mstr_cfg_bus.rdata<=4096;
      8'h48: axi_mstr_cfg_bus.rdata<=4096;
      default: axi_mstr_cfg_bus.rdata<=32'hffffffff;
    endcase
  end
  always_ff @(posedge aclk) begin
    if(!aresetn) begin
      index_q<=0;program_length<=0;tensor_count<=0;start<=0;completed<=0;configuration_error<=0;
      pv<=0;mv<=0;tv<=0;pi<=0;mi<=0;ti<=0;
      program_shift<=0;metadata_shift<=0;tensor_shift<=0;program_words<=0;metadata_words<=0;tensor_words<=0;
    end else begin
      start<=0;pv<=0;mv<=0;tv<=0;
      if(core_done) completed<=1;
      if(write_fire) begin
        if(active||start||core_fault||configuration_error) configuration_error<=1;
        else case(addr_q)
          8'h00: if(data_q==1&&hbm_ready&&program_length>0&&program_length<=4096&&tensor_count>0&&tensor_count<=4096&&
                         program_words==0&&metadata_words==0&&tensor_words==0) begin start<=1;completed<=0;end
                    else configuration_error<=1;
          8'h08: program_length<=data_q;
          8'h0c: tensor_count<=data_q;
          8'h10: index_q<=data_q;
          8'h14: if(program_words<16) begin program_shift<={data_q,program_shift[511:32]};program_words<=program_words+1;end
                    else configuration_error<=1;
          8'h18: if(data_q==1&&program_words==16&&pr&&index_q<4096) begin pi<=index_q;pv<=1;program_words<=0;end
                    else configuration_error<=1;
          8'h1c: if(metadata_words<8) begin metadata_shift<={data_q,metadata_shift[255:32]};metadata_words<=metadata_words+1;end
                    else configuration_error<=1;
          8'h20: if(data_q==1&&metadata_words==8&&mr&&index_q<4096) begin mi<=index_q;mv<=1;metadata_words<=0;end
                    else configuration_error<=1;
          8'h24: if(tensor_words<32) begin tensor_shift<={data_q,tensor_shift[1023:32]};tensor_words<=tensor_words+1;end
                    else configuration_error<=1;
          8'h28: if(data_q==1&&tensor_words==32&&tr&&index_q<4096) begin ti<=index_q;tv<=1;tensor_words<=0;end
                    else configuration_error<=1;
          default: configuration_error<=1;
        endcase
      end
    end
  end
  assign cl_axi_mstr_bus.wid=0;
  openjev_model_core core(
    .clk(aclk),.rst_n(aresetn),.program_valid(pv),.program_ready(pr),.program_index(pi),.program_data(program_shift),
    .metadata_valid(mv),.metadata_ready(mr),.metadata_index(mi),.metadata_data(metadata_shift),
    .tensor_valid(tv),.tensor_ready(tr),.tensor_index(ti),.tensor_data(tensor_shift),
    .start(start),.program_length(program_length),.tensor_count(tensor_count),.active(active),.done(core_done),
    .fault(core_fault),.fault_code(core_fault_code),.cycles(cycles),.instructions_retired(retired),
    .araddr(cl_axi_mstr_bus.araddr),
    .arlen(cl_axi_mstr_bus.arlen),
    .arsize(cl_axi_mstr_bus.arsize),
    .arburst(cl_axi_mstr_bus.arburst),
    .arid(cl_axi_mstr_bus.arid),
    .arvalid(cl_axi_mstr_bus.arvalid),
    .arready(cl_axi_mstr_bus.arready),
    .rdata(cl_axi_mstr_bus.rdata),
    .rresp(cl_axi_mstr_bus.rresp),
    .rid(cl_axi_mstr_bus.rid),
    .rlast(cl_axi_mstr_bus.rlast),
    .rvalid(cl_axi_mstr_bus.rvalid),
    .rready(cl_axi_mstr_bus.rready),
    .awaddr(cl_axi_mstr_bus.awaddr),
    .awlen(cl_axi_mstr_bus.awlen),
    .awsize(cl_axi_mstr_bus.awsize),
    .awburst(cl_axi_mstr_bus.awburst),
    .awid(cl_axi_mstr_bus.awid),
    .awvalid(cl_axi_mstr_bus.awvalid),
    .awready(cl_axi_mstr_bus.awready),
    .wdata(cl_axi_mstr_bus.wdata),
    .wstrb(cl_axi_mstr_bus.wstrb),
    .wlast(cl_axi_mstr_bus.wlast),
    .wvalid(cl_axi_mstr_bus.wvalid),
    .wready(cl_axi_mstr_bus.wready),
    .bresp(cl_axi_mstr_bus.bresp),
    .bid(cl_axi_mstr_bus.bid),
    .bvalid(cl_axi_mstr_bus.bvalid),
    .bready(cl_axi_mstr_bus.bready));
endmodule
