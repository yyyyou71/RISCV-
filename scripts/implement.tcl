set project_root [file normalize [file join [file dirname [info script]] ..]]
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG484
foreach source_file [glob [file join $project_root rtl *.v] [file join $project_root board *.v]] {
    add_design -verilog $source_file
}
add_design [file join $project_root ipcore pango_rom pango_rom.idf]
add_design [file join $project_root ipcore pango_ram pango_ram.idf]
add_constraint -fdc [file join $project_root board pins.fdc]
add_constraint -fdc [file join $project_root board timing.fdc]
compile -top_module board_top
synthesize -ads -frequency 25
dev_map
pnr -report_timing
report_timing -report_exception TRUE
gen_bit_stream
