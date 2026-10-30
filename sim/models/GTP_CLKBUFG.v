// Simulation-only transparent model matching the vendor global clock primitive.
module GTP_CLKBUFG(input wire CLKIN,output wire CLKOUT);
    assign CLKOUT=CLKIN;
endmodule
