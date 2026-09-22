# Out-of-context synthesis; reports are not routed shell timing closure.
set source_dir [file dirname [file normalize [info script]]]
set_param general.maxThreads 4
foreach top {openjev_command_scheduler openjev_hbm_vector} {
  create_project -in_memory -part xcvu47p-fsvh2892-2L-e
  foreach source {openjev_fp32_pkg openjev_fp32_alu openjev_scalar openjev_vector openjev_hbm_activation_writer openjev_hbm_vector openjev_command_scheduler} {
    read_verilog -sv ${source_dir}/../rtl/${source}.sv
  }
  if {$top eq "openjev_command_scheduler"} {
    synth_design -top $top -mode out_of_context -generic {ENABLED_ENGINES=3'b001}
  } else {
    synth_design -top $top -mode out_of_context
  }
  create_clock -period 4.000 [get_ports clk]
  report_utilization -file ${top}_utilization.rpt
  report_timing_summary -file ${top}_synth_timing.rpt
  write_checkpoint -force ${top}_synth.dcp
  close_project
}
