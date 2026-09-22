# Run independently against the completed checkpoint before AFI submission.
if {$argc != 2} {
    error "Usage: vivado -mode batch -source validate_routed.tcl -tclargs ROUTED_DCP REPORT_DIRECTORY"
}
set routed_checkpoint [lindex $argv 0]
set validation_directory [lindex $argv 1]
if {[string match "*.VIOLATED.dcp" $routed_checkpoint]} {
    error "Refusing a checkpoint marked as timing violated"
}
file mkdir $validation_directory
open_checkpoint $routed_checkpoint
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose \
    -file $validation_directory/timing_summary.rpt
report_route_status -file $validation_directory/route_status.rpt
report_drc -file $validation_directory/drc.rpt
set setup_failures [get_timing_paths -quiet -delay_type max -slack_lesser_than 0 -max_paths 1]
set hold_failures [get_timing_paths -quiet -delay_type min -slack_lesser_than 0 -max_paths 1]
set drc_errors [get_drc_violations -quiet -filter {SEVERITY == Error}]
if {[llength $setup_failures] || [llength $hold_failures] || [llength $drc_errors]} {
    error "Routed validation failed: setup=[llength $setup_failures] hold=[llength $hold_failures] DRC errors=[llength $drc_errors]"
}
puts "PASS routed setup, hold and DRC error checks; review route status and unconstrained-path report before submission"
close_design
