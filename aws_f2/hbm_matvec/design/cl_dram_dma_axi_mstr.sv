// OpenJEV HBM matrix-vector master for the AWS F2 DMA/HBM shell.
// The AWS axi_bus_t "slave" modport drives master requests.
module cl_dram_dma_axi_mstr (
  input logic aclk, aresetn,
  input logic hbm_ready,
  axi_bus_t.slave cl_axi_mstr_bus,
  cfg_bus_t.slave axi_mstr_cfg_bus
);
  logic wr_q, rd_q;
  logic [7:0] addr_q;
  logic [31:0] data_q, columns, rows, base, result_index;
  logic start, active, completed, error;
  logic [31:0] cycles, requests, results, activation_bytes;
  logic [2:0] pack_index;
  logic [255:0] activation;
  logic activation_valid, activation_ready;
  logic compute_ready, compute_error, compute_done;
  logic reader_ready, reader_error, reader_fault;
  logic request_valid, request_ready, response_ready, half_q;
  logic [4:0] bank;
  logic [28:0] address;
  logic [1:0] response_status;
  logic weight_valid, weight_ready;
  logic [255:0] weight_data;
  logic result_valid;
  logic [31:0] result_data, result_row, result_q;
  (* ram_style = "block" *) logic [31:0] result_mem [0:8191];
  logic [31:0] byte_count;
  logic [32:0] allocation_end;
  // Configuration transactions are separated by the registered CFG handshake.
  // Pipeline size/bounds arithmetic rather than adding it to the start path.
  // Widths cover all accepted dimensions, which are separately range checked.
  always_ff @(posedge aclk) begin
    byte_count <= {19'b0,columns[12:0]} * {18'b0,rows[13:0]};
    allocation_end <= {1'b0,base} +
        ((({1'b0,byte_count} + 33'd8191) >> 13) << 8);
  end
  wire can_load = active && activation_ready && !activation_valid &&
      activation_bytes < columns && !error;
  wire write_fire = wr_q && !axi_mstr_cfg_bus.ack;

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
    result_q <= result_mem[result_index[12:0]];
    if (result_valid) result_mem[result_row[12:0]] <= result_data;
    case (addr_q)
      8'h00: axi_mstr_cfg_bus.rdata <= 32'h48424d31;
      8'h04: axi_mstr_cfg_bus.rdata <= {27'b0,hbm_ready,can_load,error,completed,active};
      8'h08: axi_mstr_cfg_bus.rdata <= columns;
      8'h0c: axi_mstr_cfg_bus.rdata <= rows;
      8'h10: axi_mstr_cfg_bus.rdata <= base;
      8'h14: axi_mstr_cfg_bus.rdata <= cycles;
      8'h18: axi_mstr_cfg_bus.rdata <= requests;
      8'h1c: axi_mstr_cfg_bus.rdata <= results;
      8'h24: axi_mstr_cfg_bus.rdata <= activation_bytes;
      8'h28: axi_mstr_cfg_bus.rdata <= result_index;
      8'h2c: axi_mstr_cfg_bus.rdata <= result_q;
      default: axi_mstr_cfg_bus.rdata <= 32'hffffffff;
    endcase
  end

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      columns <= 0; rows <= 0; base <= 0; result_index <= 0;
      start <= 0; active <= 0; completed <= 0; error <= 0;
      cycles <= 0; requests <= 0; results <= 0;
      activation_bytes <= 0; pack_index <= 0;
      activation <= 0; activation_valid <= 0;
    end else begin
      start <= 0;
      if (activation_valid && activation_ready) activation_valid <= 0;
      if (active && !cycles[31]) cycles <= cycles + 1;
      if (request_valid && request_ready) requests <= requests + 1;
      if (result_valid) results <= results + 1;
      if (compute_done) begin active <= 0; completed <= !error; end
      // Faults are sticky until a shell reset. Never report success after a fault.
      if (compute_error || reader_error || reader_fault || (active && cycles[31])) begin
        error <= 1; completed <= 0;
      end
      if (write_fire) begin
        case (addr_q)
          8'h00: if (data_q == 1) begin
            if (!active && !error && compute_ready && reader_ready && hbm_ready &&
                columns > 0 && columns <= 4096 && columns[4:0] == 0 &&
                rows > 0 && rows <= 8192 && base[31:29] == 0 &&
                base[11:0] == 0 && allocation_end <= 33'h020000000) begin
              start <= 1; active <= 1; completed <= 0;
              cycles <= 0; requests <= 0; results <= 0;
              activation_bytes <= 0; pack_index <= 0; activation_valid <= 0;
            end else begin error <= 1; completed <= 0; end
          end
          8'h08: if (!active) columns <= data_q;
          8'h0c: if (!active) rows <= data_q;
          8'h10: if (!active) base <= data_q;
          8'h20: if (can_load) begin
            activation[pack_index*32 +: 32] <= data_q;
            pack_index <= pack_index + 1;
            activation_bytes <= activation_bytes + 4;
            if (pack_index == 7) activation_valid <= 1;
          end else begin error <= 1; completed <= 0; end
          8'h28: result_index <= data_q;
          default: ;
        endcase
      end
    end
  end

  assign cl_axi_mstr_bus.awid = 0;
  assign cl_axi_mstr_bus.awaddr = 0;
  assign cl_axi_mstr_bus.awlen = 0;
  assign cl_axi_mstr_bus.awsize = 6;
  assign cl_axi_mstr_bus.awburst = 1;
  assign cl_axi_mstr_bus.awvalid = 0;
  assign cl_axi_mstr_bus.wid = 0;
  assign cl_axi_mstr_bus.wdata = 0;
  assign cl_axi_mstr_bus.wstrb = 0;
  assign cl_axi_mstr_bus.wlast = 0;
  assign cl_axi_mstr_bus.wvalid = 0;
  assign cl_axi_mstr_bus.bready = 1;
  assign cl_axi_mstr_bus.arid = 0;
  assign cl_axi_mstr_bus.araddr = 64'h1000000000 + {30'b0,bank,address[28:6],6'b0};
  assign cl_axi_mstr_bus.arlen = 0;
  assign cl_axi_mstr_bus.arsize = 6;
  assign cl_axi_mstr_bus.arburst = 1;
  assign cl_axi_mstr_bus.arvalid = request_valid;
  assign request_ready = cl_axi_mstr_bus.arready;
  assign cl_axi_mstr_bus.rready = response_ready;
  // A 64-byte aligned AXI read supports the shell's 512-bit DMA datapath.
  // Select the requested 32-byte half after the address handshake.
  always_ff @(posedge aclk)
    if (!aresetn) half_q <= 0;
    else if (request_valid && request_ready) half_q <= address[5];
  assign response_status = (!cl_axi_mstr_bus.rlast || cl_axi_mstr_bus.rid != 0)
      ? 2'b10 : cl_axi_mstr_bus.rresp;

  openjev_hbm_weight_reader reader (
    .clk(aclk),.rst_n(aresetn),.command_valid(start),.command_ready(reader_ready),
    .base_address(base[28:0]),.byte_count(byte_count),.command_error(reader_error),
    .request_valid(request_valid),.request_ready(request_ready),
    .request_bank(bank),.request_address(address),
    .response_valid(cl_axi_mstr_bus.rvalid),.response_ready(response_ready),
    .response_data(half_q ? cl_axi_mstr_bus.rdata[511:256] : cl_axi_mstr_bus.rdata[255:0]),
    .response_status(response_status),.weight_valid(weight_valid),.weight_ready(weight_ready),
    .weight_data(weight_data),.weight_last(),.done(),.fault(reader_fault)
  );
  openjev_int8_matvec compute (
    .clk(aclk),.rst_n(aresetn),.command_valid(start),.command_ready(compute_ready),
    .columns(columns),.rows(rows),.command_error(compute_error),
    .activation_valid(activation_valid),.activation_ready(activation_ready),.activation_data(activation),
    .weight_valid(weight_valid),.weight_ready(weight_ready),.weight_data(weight_data),
    .result_valid(result_valid),.result_ready(1'b1),.result_data(result_data),.result_row(result_row),
    .result_last(),.busy(),.done(compute_done)
  );
endmodule
