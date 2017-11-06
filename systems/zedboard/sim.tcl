source sim_waves.tcl

proc reset_sim { } {
    catch { close_sim -force }
    catch { reset_simulation -simset sim_1 -mode behavioral }
    catch { reset_target simulation [get_files *design_1.bd] }
    exec rm -rf project/project.ip_user_files
    update_ip_catalog -rebuild -scan_changes
    upgrade_ip [get_ips *]
    report_ip_status -name ip_status
    generate_target simulation [get_files *design_1.bd]
}

proc start_sim { {run_time 0} } {
    catch { launch_simulation }

    set reset_time 1000

    reset_waves
    
    restart
    log_wave -r *

    #Reset from the PS doesn't get generated automatically
    add_force /design_1_wrapper/design_1_i/processing_system7_0_FCLK_RESET0_N 0 0us 1 $reset_time
    
    #Was getting simulation errors from this port;
    #should not be actually used in simulation so forcing the clock to 0
    #Note there's a 'dummy' hierarchy that prevents this from
    #also forcing the CPU clock in simulation but that is a simple passthrough
    #when synthesized
    add_force /design_1_wrapper/design_1_i/processing_system7/S_AXI_GP0_ACLK 0 0us

    #Turn on UART bypass module
    add_force /design_1_wrapper/design_1_i/xlconstant_bypass_ps7_uart_dout   1 0us

    #Run until reset is about to be removed then set up BRAMs
    run [expr $reset_time]

    set coe_file [open "software/test.coe" r]
    set coe_data [read $coe_file]
    close $coe_file

    set i 0
    set data [split $coe_data "\n"]
    foreach line $data {
        set words [regexp -all -inline {\S+} $line]
        #puts $words
        foreach word $words {
            set byte0 ""
            append byte0 [string index $word 6]
            append byte0 [string index $word 7]
            set_value "/design_1_wrapper/design_1_i/idram/U0/ram/\\idram_gen(0)\\/tdp_ram/ram[$i]" -radix hex $byte0 
            set byte1 ""
            append byte1 [string index $word 4]
            append byte1 [string index $word 5]
            set_value "/design_1_wrapper/design_1_i/idram/U0/ram/\\idram_gen(1)\\/tdp_ram/ram[$i]" -radix hex $byte1
            set byte2 ""
            append byte2 [string index $word 2]
            append byte2 [string index $word 3]
            set_value "/design_1_wrapper/design_1_i/idram/U0/ram/\\idram_gen(2)\\/tdp_ram/ram[$i]" -radix hex $byte2 
            set byte3 "" 
            append byte3 [string index $word 0]
            append byte3 [string index $word 1]
            set_value "/design_1_wrapper/design_1_i/idram/U0/ram/\\idram_gen(3)\\/tdp_ram/ram[$i]" -radix hex $byte3 
            set i [expr {$i + 1}]
        }
    }
    run $run_time
}
