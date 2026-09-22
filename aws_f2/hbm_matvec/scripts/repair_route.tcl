# Resume a routed checkpoint without changing clocks or timing exceptions.
# vivado -mode batch -source repair_route.tcl -tclargs INPUT_DCP OUTPUT_PREFIX
if {$argc != 2} { error "Expected INPUT_DCP OUTPUT_PREFIX" }
set input_dcp [lindex $argv 0]
set output_prefix [lindex $argv 1]
set_param general.maxThreads 4
open_checkpoint $input_dcp
phys_opt_design -directive AggressiveExplore
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose -file ${output_prefix}.timing.rpt
report_route_status -file ${output_prefix}.routing.rpt
report_drc -file ${output_prefix}.drc.rpt
set setup_paths [get_timing_paths -delay_type max -slack_lesser_than 0 -max_paths 1]
set hold_paths [get_timing_paths -delay_type min -slack_lesser_than 0 -max_paths 1]
if {[llength $setup_paths] || [llength $hold_paths]} {
    write_checkpoint -force ${output_prefix}.VIOLATED.dcp
    error "Timing repair did not close setup and hold; inspect reports"
}
write_checkpoint -force ${output_prefix}.dcp
puts "OPENJEV_REPAIR_TIMING_PASS"
close_design
