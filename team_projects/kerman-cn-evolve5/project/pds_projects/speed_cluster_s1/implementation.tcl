set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG484
add_design -verilog "rv32_board_design.v"
add_constraint -fdc "board_io_reference.fdc"
add_constraint -fdc "timing.fdc"
compile -top_module board_top
synthesize -ads -frequency 25
dev_map
pnr -report_timing -plc_decongestion 3 -gplace_seed 1 -groute_seed 1 -optimize_multi_corner_timing -fix_hold_violation -fix_hold_violation_iterations 20 -fix_hold_violation_threshold 200 -fix_hold_violation_in_route TRUE -fix_hold_violation_threshold_for_clk_tree 200 -fix_hold_violation_threshold_for_clock_path_cross_srb 1800 -max_hold_violated_paths_num 100000
report_timing -report_exception TRUE
gen_bit_stream
