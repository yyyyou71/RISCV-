set project_root [file normalize [file dirname [info script]]]
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG484
foreach name {fspi_loopback_top.v rk_fspi_adapter.v board_reset.v} {
 add_design -verilog [file join $project_root $name]
}
add_constraint -fdc [file join $project_root pins.fdc]
add_constraint -fdc [file join $project_root timing.fdc]
compile -top_module fspi_loopback_top
synthesize -ads -frequency 25
dev_map
pnr -report_timing
report_timing -report_exception TRUE
gen_bit_stream
