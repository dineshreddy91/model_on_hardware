# Standalone synthesis only; this is not shell place-and-route timing closure.
set source_dir [file dirname [file normalize [info script]]]
foreach top {openjev_int8_matvec openjev_hbm_weight_reader} {
  create_project -in_memory -part xcvu47p-fsvh2892-2L-e
  read_verilog -sv ${source_dir}/../rtl/${top}.sv
  synth_design -top $top -mode out_of_context
  create_clock -period 4.000 [get_ports clk]
  report_utilization -file ${top}_utilization.rpt
  report_timing_summary -file ${top}_synth_timing.rpt
  write_checkpoint -force ${top}_synth.dcp
  close_project
}
