// Bring-up source only: constant RGB565 red, matching the original MODE 0.
// All inputs/outputs belong to the PCIe pclk_div2 domain.
// This module does not configure the PCIe core or start DMA transactions.
module pcie_test_source #(
    parameter [15:0] PIXEL = 16'hF800
) (
    input  wire         rst_n,
    output wire [127:0] data,
    output wire         valid,
    output wire         sufficient
);
    assign data = {8{PIXEL}};
    assign valid = rst_n;
    assign sufficient = rst_n;
endmodule
