source ${HDK_SHELL_DIR}/build/scripts/synth_cl_header.tcl

print "Reading encrypted user source files"
read_verilog -sv [glob ${src_post_enc_dir}/*.{s,}v]

print "Reading CL IP blocks"
read_ip ${HDK_IP_SRC_DIR}/axi_register_slice_light/axi_register_slice_light.xci
read_ip ${HDK_IP_SRC_DIR}/cl_debug_bridge/cl_debug_bridge.xci

print "Reading user constraints"
read_xdc [ list \
  ${constraints_dir}/cl_synth_user.xdc \
  ${constraints_dir}/cl_timing_user.xdc
]
set_property PROCESSING_ORDER LATE [get_files cl_synth_user.xdc]
set_property PROCESSING_ORDER LATE [get_files cl_timing_user.xdc]

print "Starting synthesis of customer's design ${CL}"
update_compile_order -fileset sources_1
synth_design -mode out_of_context \
             -top ${CL} \
             -verilog_define XSDB_SLV_DIS \
             -part ${DEVICE_TYPE} \
             -keep_equivalent_registers

source ${HDK_SHELL_DIR}/build/scripts/synth_cl_footer.tcl
