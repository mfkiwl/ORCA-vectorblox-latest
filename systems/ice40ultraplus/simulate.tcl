
proc com { args } {
    set fileset [list \
                     ../../rtl/utils.vhd                \
                     ../../rtl/constants_pkg.vhd        \
                     ../../rtl/components.vhd           \
                     ../../rtl/alu.vhd                  \
                     ../../rtl/branch_unit.vhd          \
                     ../../rtl/decode.vhd               \
                     ../../rtl/execute.vhd              \
                     ../../rtl/instruction_fetch.vhd    \
                     ../../rtl/load_store_unit.vhd      \
                     ../../rtl/register_file.vhd        \
                     ../../rtl/orca.vhd                 \
                     ../../rtl/orca_core.vhd            \
                     ../../rtl/sys_call.vhd             \
                     ../../rtl/memory_interface.vhd     \
                     ../../rtl/cache_mux.vhd            \
							../../rtl/oimm_register.vhd        \
							../../rtl/lve/lve_components.vhd   \
                     ../../rtl/lve/lve_ci.vhd           \
							../../rtl/lve/lve_core.vhd         \
							../../rtl/lve/lve.vhd              \
                     ../../rtl/lve/4port_mem_ultraplus.vhd  \
                     hdl/top_util_pkg.vhd               \
                     hdl/top_component_pkg.vhd          \
                     hdl/wb_ram.vhd                     \
                     hdl/wb_cam.vhd                     \
                     hdl/wb_arbiter.vhd                 \
                     hdl/wb_splitter.vhd                \
                     hdl/wb_pio.vhd                     \
                     hdl/uart_tb.vhd                    \
                     hdl/bram.vhd                       \
                     hdl/my_led_sim.v                   \
                     hdl/uart_rd1042/uart_core.vhd      \
                     hdl/uart_rd1042/modem.vhd          \
                     hdl/uart_rd1042/rxcver.vhd         \
                     hdl/uart_rd1042/txcver_fifo.vhd    \
                     hdl/uart_rd1042/rxcver_fifo.vhd    \
                     hdl/uart_rd1042/intface.vhd        \
                     hdl/uart_rd1042/txmitt.vhd         \
                     hdl/pmod_mic/pmod_mic_wb.vhd       \
                     hdl/pmod_mic/pmod_mic_ref_comp.vhd \
                     hdl/osc_hf.vhd                     \
                     hdl/SB_GB_sim.vhd                  \
                     hdl/i2s_interface/i2s_decode.vhd   \
                     hdl/i2s_interface/i2s_wb.vhd       \
                     top.vhd                            \
                     top_top.v                          \
                     hdl/i2s_tx/i2s_codec.vhd           \
                     hdl/i2s_tx/tx_i2s_pack.vhd         \
                     hdl/i2s_tx/gen_control_reg.vhd     \
                     hdl/i2s_tx/i2s_version.vhd         \
                     hdl/i2s_tx/dpram_rtl.vhd           \
                     hdl/i2s_tx/gen_event_reg.vhd       \
                     hdl/i2s_tx/tx_i2s_wbd.vhd          \
                     hdl/i2s_tx/tx_i2s_topm.vhd         \
                     hdl/wb_flash_dma.vhd               \
                     hdl/spi_master/wb_spi_simple.vhd   \
                     hdl/fmf/gen_utils.vhd              \
                     hdl/fmf/switch_pkg.vhd             \
                     hdl/fmf/conversions.vhd            \
                     hdl/fmf/ecl_utils.vhd              \
                     hdl/fmf/ecl_package.vhd            \
                     hdl/fmf/ff_package.vhd             \
                     hdl/fmf/state_tab_package.vhd      \
                     hdl/fmf/memory.vhd                 \
                     hdl/fmf/m25p80.vhd                 \
                     top_tb.vhd
                ]

    #set icecube2_dir /opt/lattice/lscc/iCEcube2.2016.02/
    set icecube2_dir    /nfs/opt/lattice/iCEcube2/2016.02/
    lappend fileset $icecube2_dir/verilog/ABIPTBS8.v
    lappend fileset $icecube2_dir/verilog/ABIWTCZ4.v
    lappend fileset $icecube2_dir/verilog/sb_ice_ipenc_modelsim.v
    lappend fileset $icecube2_dir/verilog/sb_ice_lc.v
    lappend fileset $icecube2_dir/verilog/sb_ice_syn.v

    ##If you want to view the ram contents of the scratchpad use this file, otherwise the Toolchain files above should work
    lappend fileset hdl/SB_SPRAM256KA.vhd


    vlib work
	 set compiletime_file "work/compile_time"
	 if { [file exists $compiletime_file  ] } {
		  set fp [open $compiletime_file "r" ]
		  set last_compile_time [read $fp ]
	 } else {
		  set last_compile_time 0
	 }
	 #if -f in args, recompile all
	 if { [string first "-f" $args ] >= 0 } {
		  set last_compile_time 0
	 }

    foreach f $fileset {
		  if { [file mtime $f] > $last_compile_time } {
				if { [file extension $f ] == ".v" } {
					 vlog -work work -stats=none $f
				} else {
					 vcom -work work -2002 -explicit $f
				}
		  }
    }
	 set fp [open $compiletime_file "w"]
	 puts $fp [clock seconds]
	 close $fp

}

source ../sim_waves.tcl
proc recom { t {extra_waves false} } {
    noview wave

    com

    vsim -t 1ns work.top_tb
    add log -r *

	 orca_reset_waves "add wave" "add wave -divider" /top_tb/dut/sub_top/WITH_LVE/rv


    run $t
}

proc rerun { t } {
    restart -f;
    run $t
}


recom 0

radix hex

config wave -signalnamewidth 2
