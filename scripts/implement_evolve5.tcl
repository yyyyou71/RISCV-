set project_root [file normalize [file join [file dirname [info script]] ..]]
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG484
add_design -verilog [file join $project_root build pds-evolve5 evolve5_design.v]
foreach name {pango_evolve_rom pango_evolve_ram pango_evolve_mul} {
    add_design [file join $project_root ipcore $name $name.idf]
}
add_constraint -fdc [file join $project_root board pins.fdc]
add_constraint -fdc [file join $project_root board timing.fdc]
compile -top_module board_top
synthesize -ads -frequency 25
dev_map
pnr -report_timing -refineplacement_cluster FALSE -gplace_seed 1 -groute_seed 1 -optimize_multi_corner_timing -fix_hold_violation -fix_hold_violation_iterations 15 -fix_hold_violation_threshold 200 -fix_hold_violation_in_route TRUE -fix_hold_violation_threshold_for_clk_tree 200 -fix_hold_violation_threshold_for_clock_path_cross_srb 400 -max_hold_violated_paths_num 100000 -plc_decongestion 3
report_timing -report_exception TRUE
gen_bit_stream
