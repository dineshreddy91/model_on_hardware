`include "cl_axil_reg_access_defines.vh"

module cl_axil_reg_access (`include "cl_ports.vh");

`include "cl_id_defines.vh"
`include "unused_flr_template.inc"
`include "unused_ddr_template.inc"
`include "unused_cl_sda_template.inc"
`include "unused_apppf_irq_template.inc"
`include "unused_dma_pcis_template.inc"
`include "unused_pcim_template.inc"

assign cl_sh_id0 = `CL_SH_ID0;
assign cl_sh_id1 = `CL_SH_ID1;

logic sh_ocl_awvalid_q;
logic [31:0] sh_ocl_awaddr_q;
logic sh_ocl_wvalid_q;
logic [31:0] sh_ocl_wdata_q;
logic [3:0] sh_ocl_wstrb_q;
logic sh_ocl_bready_q;
logic sh_ocl_arvalid_q;
logic [31:0] sh_ocl_araddr_q;
logic sh_ocl_rready_q;
logic ocl_sh_awready_q = 1'b0;
logic ocl_sh_wready_q = 1'b0;
logic ocl_sh_bvalid_q = 1'b0;
logic [1:0] ocl_sh_bresp_q = 2'b00;
logic ocl_sh_arready_q = 1'b0;
logic ocl_sh_rvalid_q = 1'b0;
logic [31:0] ocl_sh_rdata_q = 32'h0;
logic [1:0] ocl_sh_rresp_q = 2'b00;

typedef enum logic [2:0] {
  IDLE = 3'd0,
  WRITE_WAIT = 3'd1,
  WRITE = 3'd2,
  WRITE_RESP = 3'd3,
  READ = 3'd4
} axil_state_t;

axil_state_t current_state = IDLE;
axil_state_t next_state;
logic data_wr_handshake;
logic addr_rd_handshake;
logic addr_wr_handshake;
logic bresp_handshake;
logic data_rd_handshake;
logic [31:0] write_addr = 32'h0;

logic signed [7:0] activation_mem [0:1023];
logic [10:0] write_index = 11'd0;
logic [9:0] mac_index = 10'd0;
logic signed [7:0] activation_pipe = 8'sd0;
logic pipeline_valid = 1'b0;
logic pipeline_last = 1'b0;
logic signed [31:0] accumulator0 = 32'sd0;
logic signed [31:0] accumulator1 = 32'sd0;
logic signed [31:0] accumulator2 = 32'sd0;
logic signed [7:0] weight0;
logic signed [7:0] weight1;
logic signed [7:0] weight2;
logic busy = 1'b0;
logic done = 1'b0;
logic start_pulse = 1'b0;

axi_register_slice_light AXIL_OCL_REG_SLC (
  .aclk(clk_main_a0), .aresetn(rst_main_n),
  .s_axi_awaddr(ocl_cl_awaddr), .s_axi_awprot(`AXI_PROT_DEFAULT),
  .s_axi_awvalid(ocl_cl_awvalid), .s_axi_awready(cl_ocl_awready),
  .s_axi_wdata(ocl_cl_wdata), .s_axi_wstrb(ocl_cl_wstrb),
  .s_axi_wvalid(ocl_cl_wvalid), .s_axi_wready(cl_ocl_wready),
  .s_axi_bresp(cl_ocl_bresp), .s_axi_bvalid(cl_ocl_bvalid),
  .s_axi_bready(ocl_cl_bready), .s_axi_araddr(ocl_cl_araddr),
  .s_axi_arprot(`AXI_PROT_DEFAULT), .s_axi_arvalid(ocl_cl_arvalid),
  .s_axi_arready(cl_ocl_arready), .s_axi_rdata(cl_ocl_rdata),
  .s_axi_rresp(cl_ocl_rresp), .s_axi_rvalid(cl_ocl_rvalid),
  .s_axi_rready(ocl_cl_rready), .m_axi_awaddr(sh_ocl_awaddr_q),
  .m_axi_awprot(), .m_axi_awvalid(sh_ocl_awvalid_q),
  .m_axi_awready(ocl_sh_awready_q), .m_axi_wdata(sh_ocl_wdata_q),
  .m_axi_wstrb(sh_ocl_wstrb_q), .m_axi_wvalid(sh_ocl_wvalid_q),
  .m_axi_wready(ocl_sh_wready_q), .m_axi_bresp(ocl_sh_bresp_q),
  .m_axi_bvalid(ocl_sh_bvalid_q), .m_axi_bready(sh_ocl_bready_q),
  .m_axi_araddr(sh_ocl_araddr_q), .m_axi_arvalid(sh_ocl_arvalid_q),
  .m_axi_arready(ocl_sh_arready_q), .m_axi_rdata(ocl_sh_rdata_q),
  .m_axi_rresp(ocl_sh_rresp_q), .m_axi_rvalid(ocl_sh_rvalid_q),
  .m_axi_rready(sh_ocl_rready_q)
);

openjev_head_rom WEIGHT_ROM (
  .clk(clk_main_a0), .index(mac_index),
  .weight0(weight0), .weight1(weight1), .weight2(weight2)
);

always_comb begin
  addr_wr_handshake = sh_ocl_awvalid_q && ocl_sh_awready_q;
  data_wr_handshake = sh_ocl_wvalid_q && ocl_sh_wready_q;
  bresp_handshake = ocl_sh_bvalid_q && sh_ocl_bready_q;
  addr_rd_handshake = sh_ocl_arvalid_q && ocl_sh_arready_q;
  data_rd_handshake = ocl_sh_rvalid_q && sh_ocl_rready_q;
end

always_comb begin
  next_state = current_state;
  case (current_state)
    IDLE: begin
      if (addr_wr_handshake && data_wr_handshake) next_state = WRITE;
      else if (addr_wr_handshake || data_wr_handshake) next_state = WRITE_WAIT;
      else if (addr_rd_handshake) next_state = READ;
    end
    WRITE_WAIT: if (addr_wr_handshake || data_wr_handshake) next_state = WRITE;
    WRITE: next_state = WRITE_RESP;
    WRITE_RESP: if (bresp_handshake) next_state = IDLE;
    READ: if (data_rd_handshake) next_state = IDLE;
    default: next_state = IDLE;
  endcase
end

always_ff @(posedge clk_main_a0) begin
  if (!rst_main_n) current_state <= IDLE;
  else current_state <= next_state;
end

always_ff @(posedge clk_main_a0) begin
  if (addr_wr_handshake) write_addr <= sh_ocl_awaddr_q;
end

always_ff @(posedge clk_main_a0) begin
  if (!rst_main_n) begin
    ocl_sh_awready_q <= 1'b1;
    ocl_sh_wready_q <= 1'b1;
    ocl_sh_bvalid_q <= 1'b0;
    ocl_sh_bresp_q <= 2'b00;
    ocl_sh_arready_q <= 1'b1;
    ocl_sh_rvalid_q <= 1'b0;
    ocl_sh_rresp_q <= 2'b00;
  end else begin
    ocl_sh_awready_q <= (next_state == IDLE) || (next_state == WRITE_WAIT);
    ocl_sh_wready_q <= (next_state == IDLE) || (next_state == WRITE_WAIT);
    ocl_sh_bvalid_q <= (next_state == WRITE_RESP);
    ocl_sh_bresp_q <= `AXI_RESP_OKAY;
    ocl_sh_arready_q <= (next_state == IDLE);
    ocl_sh_rvalid_q <= (next_state == READ);
    ocl_sh_rresp_q <= `AXI_RESP_OKAY;
  end
end

always_ff @(posedge clk_main_a0) begin
  start_pulse <= 1'b0;
  if (!rst_main_n) begin
    write_index <= 11'd0;
  end else if (next_state == WRITE) begin
    if (write_addr == `ADDR_ACTIVATION && !busy) begin
      if (sh_ocl_wstrb_q[0]) activation_mem[write_index] <= sh_ocl_wdata_q[7:0];
      if (sh_ocl_wstrb_q[1]) activation_mem[write_index + 1] <= sh_ocl_wdata_q[15:8];
      if (sh_ocl_wstrb_q[2]) activation_mem[write_index + 2] <= sh_ocl_wdata_q[23:16];
      if (sh_ocl_wstrb_q[3]) activation_mem[write_index + 3] <= sh_ocl_wdata_q[31:24];
      if (write_index < 11'd1024) write_index <= write_index + 11'd4;
    end else if (write_addr == `ADDR_CONTROL) begin
      if (sh_ocl_wdata_q[1]) write_index <= 11'd0;
      if (sh_ocl_wdata_q[0] && write_index == 11'd1024 && !busy) start_pulse <= 1'b1;
    end
  end
end

always_ff @(posedge clk_main_a0) begin
  if (!rst_main_n) begin
    mac_index <= 10'd0;
    accumulator0 <= 32'sd0;
    accumulator1 <= 32'sd0;
    accumulator2 <= 32'sd0;
    busy <= 1'b0;
    done <= 1'b0;
    activation_pipe <= 8'sd0;
    pipeline_valid <= 1'b0;
    pipeline_last <= 1'b0;
  end else if (start_pulse) begin
    mac_index <= 10'd0;
    accumulator0 <= 32'sd0;
    accumulator1 <= 32'sd0;
    accumulator2 <= 32'sd0;
    busy <= 1'b1;
    done <= 1'b0;
    pipeline_valid <= 1'b0;
    pipeline_last <= 1'b0;
  end else if (busy) begin
    activation_pipe <= activation_mem[mac_index];
    pipeline_valid <= 1'b1;
    pipeline_last <= mac_index == 10'd1023;
    if (mac_index != 10'd1023)
      mac_index <= mac_index + 10'd1;
    if (pipeline_valid) begin
      accumulator0 <= accumulator0 + $signed(activation_pipe) * $signed(weight0);
      accumulator1 <= accumulator1 + $signed(activation_pipe) * $signed(weight1);
      accumulator2 <= accumulator2 + $signed(activation_pipe) * $signed(weight2);
      if (pipeline_last) begin
        busy <= 1'b0;
        done <= 1'b1;
        pipeline_valid <= 1'b0;
      end
    end
  end
end

always_ff @(posedge clk_main_a0) begin
  if (addr_rd_handshake) begin
    case (sh_ocl_araddr_q)
      `ADDR_ACCUMULATOR0: ocl_sh_rdata_q <= accumulator0;
      `ADDR_ACCUMULATOR1: ocl_sh_rdata_q <= accumulator1;
      `ADDR_ACCUMULATOR2: ocl_sh_rdata_q <= accumulator2;
      `ADDR_STATUS: ocl_sh_rdata_q <= {18'd0, write_index[10:0], done, busy, start_pulse};
      `ADDR_WRITE_COUNT: ocl_sh_rdata_q <= {21'd0, write_index};
      default: ocl_sh_rdata_q <= `INVALID_ADDR_RESP;
    endcase
  end
end

`ifndef SIMULATION
cl_debug_bridge CL_DEBUG_BRIDGE (
  .clk(clk_main_a0), .S_BSCAN_drck(drck), .S_BSCAN_shift(shift),
  .S_BSCAN_tdi(tdi), .S_BSCAN_update(update), .S_BSCAN_sel(sel),
  .S_BSCAN_tdo(tdo), .S_BSCAN_tms(tms), .S_BSCAN_tck(tck),
  .S_BSCAN_runtest(runtest), .S_BSCAN_reset(reset),
  .S_BSCAN_capture(capture), .S_BSCAN_bscanid_en(bscanid_en)
);
`endif

endmodule
