`timescale 1ns/1ps
module tb_openjev_operator_watchdog;
  reg clk=0,rst_n=0,command_valid=0;
  always #5 clk=~clk;
  wire afault,dfault,adone,ddone,ar,dr,ao,do_valid,ac,dc;
  wire [3:0] afc,dfc;
  openjev_attention #(.MAX_KEYS(2),.MAX_DIM(2),.WATCHDOG_CYCLES(8)) attention(
    .clk(clk),.rst_n(rst_n),.command_valid(command_valid),.command_ready(ac),
    .query_count(32'd1),.key_count(32'd1),.head_dim(32'd1),.query_offset(32'd0),
    .causal(1'b0),.use_key_mask(1'b0),.read_valid(ar),.read_ready(1'b0),
    .response_valid(1'b0),.response_data(32'd0),.response_error(1'b0),
    .output_valid(ao),.output_ready(1'b0),.done(adone),.fault(afault),.fault_code(afc));
  openjev_gated_delta #(.MAX_KEY_DIM(2),.MAX_VALUE_DIM(2),.MAX_TOKENS(2),.WATCHDOG_CYCLES(8)) delta(
    .clk(clk),.rst_n(rst_n),.command_valid(command_valid),.command_ready(dc),
    .token_count(32'd1),.key_dim(32'd1),.value_dim(32'd1),
    .initial_state_from_memory(1'b0),.reuse_state(1'b0),.read_valid(dr),.read_ready(1'b0),
    .response_valid(1'b0),.response_data(32'd0),.response_error(1'b0),
    .output_valid(do_valid),.output_ready(1'b0),.done(ddone),.fault(dfault),.fault_code(dfc));
  initial begin
    repeat(3) @(negedge clk);rst_n=1;command_valid=1;
    @(negedge clk);command_valid=0;
    repeat(12) @(negedge clk);
    if(!afault||!dfault||afc!=5||dfc!=5||adone||ddone) $fatal(1,"watchdog failure");
    repeat(5) @(negedge clk);
    if(ar||dr||ao||do_valid||ac||dc) $fatal(1,"fault containment failure");
    rst_n=0;repeat(2) @(negedge clk);rst_n=1;@(negedge clk);
    if(afault||dfault||!ac||!dc) $fatal(1,"fault reset failure");
    $display("PASS attention and gated-delta bounded watchdog, sticky fault, reset");
    $finish;
  end
endmodule
