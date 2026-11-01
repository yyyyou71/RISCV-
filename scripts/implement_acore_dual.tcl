set project_root [file normalize [file join [file dirname [info script]] ..]]
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG484
foreach source_file [glob [file join $project_root rtl *.v] [file join $project_root rtl rk_fspi *.v] [file join $project_root board *.v]] {
    add_design -verilog $source_file
}
foreach name {pango_acore_fetch pango_acore_ram pango_multiplier_ip} {
    add_design [file join $project_root ipcore $name $name.idf]
}
add_constraint -fdc [file join $project_root board pins.fdc]
add_constraint -fdc [file join $project_root board timing.fdc]
compile -top_module acore_dual_top
synthesize -ads -frequency 25
dev_map
pnr -report_timing -refineplacement_cluster FALSE -gplace_seed 2 -groute_seed 2 -optimize_multi_corner_timing -fix_hold_violation -fix_hold_violation_iterations 15 -fix_hold_violation_threshold 200 -fix_hold_violation_in_route TRUE -fix_hold_violation_threshold_for_clk_tree 200 -fix_hold_violation_threshold_for_clock_path_cross_srb 400 -max_hold_violated_paths_num 100000 -plc_decongestion 3
report_timing -report_exception TRUE
gen_bit_stream
