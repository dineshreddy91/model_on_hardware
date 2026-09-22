set root [file normalize [file join [file dirname [info script]] ..]]
set_param general.maxThreads 4
create_project -in_memory -part xcvu47p-fsvh2892-2L-e
read_verilog -sv $root/rtl/openjev_fp32_pkg.sv
foreach source [lsort [glob $root/rtl/*.sv]] {
  if {[file tail $source] ne "openjev_fp32_pkg.sv"} {read_verilog -sv $source}
}
synth_design -top openjev_model_core -mode out_of_context
create_clock -period 4.000 [get_ports clk]
report_utilization -file model_core_utilization.rpt
report_timing_summary -file model_core_synth_timing.rpt
report_timing -max_paths 10 -file model_core_paths.rpt
write_checkpoint -force model_core_synth.dcp
