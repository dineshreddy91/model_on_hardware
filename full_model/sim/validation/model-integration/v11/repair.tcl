set_param general.maxThreads 4
open_checkpoint /home/ubuntu/openjev-full-shell-v10/cl_dram_hbm_dma/build/checkpoints/cl_dram_hbm_dma.openjev_full_model_v1.post_route.VIOLATED.dcp
set detail [open critical_endpoints.txt w]
foreach path [get_timing_paths -delay_type max -max_paths 50 -nworst 1 -slack_lesser_than 0] {
  puts $detail "SLACK=[get_property SLACK $path] START=[get_property STARTPOINT_PIN $path] END=[get_property ENDPOINT_PIN $path]"
}
close $detail
phys_opt_design -directive AggressiveFanoutOpt
write_checkpoint -force post_phys_opt.dcp
route_design -directive Explore -tns_cleanup
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose -file timing_summary.rpt
report_route_status -file route_status.rpt
report_drc -file drc.rpt
report_bus_skew -file bus_skew.rpt
set setup [get_timing_paths -max_paths 1 -slack_lesser_than 0 -setup]
set hold [get_timing_paths -max_paths 1 -slack_lesser_than 0 -hold]
if {[llength $setup] || [llength $hold]} {
  write_checkpoint -force post_route.VIOLATED.dcp
  error "Timing still fails; do not deploy"
}
write_checkpoint -force post_route.dcp
puts "TIMING_PASS: independent DRC, route, bus-skew and unconstrained-path review still required"
