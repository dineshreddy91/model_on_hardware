if {[llength [glob -nocomplain -dir $src_post_enc_dir *]] != 0} {
  eval file delete -force [glob $src_post_enc_dir/*]
}

set UNUSED_TEMPLATES_DIR $HDK_SHELL_DESIGN_DIR/interfaces
file copy -force $UNUSED_TEMPLATES_DIR/unused_flr_template.inc        $src_post_enc_dir
file copy -force $UNUSED_TEMPLATES_DIR/unused_ddr_template.inc        $src_post_enc_dir
file copy -force $UNUSED_TEMPLATES_DIR/unused_cl_sda_template.inc     $src_post_enc_dir
file copy -force $UNUSED_TEMPLATES_DIR/unused_apppf_irq_template.inc  $src_post_enc_dir
file copy -force $UNUSED_TEMPLATES_DIR/unused_dma_pcis_template.inc   $src_post_enc_dir
file copy -force $UNUSED_TEMPLATES_DIR/unused_pcim_template.inc       $src_post_enc_dir
file copy -force $CL_DIR/design/cl_id_defines.vh                      $src_post_enc_dir
file copy -force $CL_DIR/design/cl_axil_reg_access_defines.vh         $src_post_enc_dir
file copy -force $CL_DIR/design/cl_axil_reg_access.sv                 $src_post_enc_dir
file copy -force $CL_DIR/design/openjev_head_rom.sv                   $src_post_enc_dir
file copy -force $CL_DIR/design/openjev_weight0.mem                   $src_post_enc_dir
file copy -force $CL_DIR/design/openjev_weight1.mem                   $src_post_enc_dir
file copy -force $CL_DIR/design/openjev_weight2.mem                   $src_post_enc_dir

exec chmod +w {*}[glob ${src_post_enc_dir}/*]
if {$ENCRYPT} {
  print "Encryption enabled. Encrypting HDL files and DCPs."
  encrypt -k ${HDK_SHELL_DIR}/build/scripts/vivado_keyfile.txt -lang verilog -quiet [glob -nocomplain -- ${src_post_enc_dir}/*.{v,sv,vh,inc}]
  encrypt -k ${HDK_SHELL_DIR}/build/scripts/vivado_vhdl_keyfile.txt -lang vhdl -quiet [glob -nocomplain -- ${src_post_enc_dir}/*.vhd?]
} else {
  print "Encryption disabled."
}
