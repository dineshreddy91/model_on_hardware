# OOC timing is a diagnostic, not routed shell timing closure.
set source_dir [file dirname [file normalize [info script]]]
set_param general.maxThreads 4
set tops {openjev_fp32_alu openjev_hbm_vector openjev_tensor_memory openjev_head_dispatch}
if {[info exists ::env(OPENJEV_SYNTH_TOP)]} { set tops [list $::env(OPENJEV_SYNTH_TOP)] }
foreach top $tops {
  create_project -in_memory -part xcvu47p-fsvh2892-2L-e
  foreach source {fp32_pkg fp32_alu scalar special vector hbm_activation_writer hbm_vector attention gated_delta head_dispatch hbm_element tensor_address tensor_memory} {
    read_verilog -sv ${source_dir}/../rtl/openjev_${source}.sv
  }
  synth_design -top $top -mode out_of_context
  create_clock -period 4.000 [get_ports clk]
  report_utilization -file ${top}_utilization.rpt
  report_timing_summary -file ${top}_synth_timing.rpt
  report_timing -max_paths 5 -file ${top}_paths.rpt
  write_checkpoint -force ${top}_synth.dcp
  close_project
}
