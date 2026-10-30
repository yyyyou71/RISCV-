# Independent core check, generated project stays under ignored build/.
# The only maintained board project remains root rv32I.pds.
set project_root [file normalize [file join [file dirname [info script]] ..]]
set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG484
foreach name {pool_sum_ram rgb_mean240 rgb888_pool96} {
    add_design -verilog [file join $project_root rtl video preprocess $name.v]
}
add_design [file join $project_root ipcore pango_pool_sum_ram pango_pool_sum_ram.idf]
add_constraint -fdc [file join $project_root sim video preprocess_synthesis.fdc]
compile -top_module rgb888_pool96
synthesize -ads -frequency 148.5 -disable_io_insertion
