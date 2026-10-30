`timescale 1ns / 1ps
module hdmi_in_demo(
    input  wire         sys_clk,
    output              rstn_out,

    // HDMI Ӳ���ź�
    output              hd_scl,
    inout               hd_sda,
    output              rx_rst_n,

    // ===================== ������Ӳ���������ź� =====================
    input               pixclk_in,
    input               vs_in,
    input               hs_in,
    input               de_in,
    input        [7:0]  r_in,
    input        [7:0]  g_in,
    input        [7:0]  b_in,

    // ===================== �����? DDR ģ�飨�����У���=====================
    output              pixclk_out,
    output              vs_out,
    output              hs_out,
    output              de_out,
    output       [15:0] pixel_16bit_out
);

wire                cfg_clk;
wire                locked;
wire                init_over;
wire                rx_init_done;
reg         [15:0]  rstn_1ms;

PLL_CLK u_PLL_CLK (
    .clkout0 (cfg_clk),
    .lock    (locked),
    .clkin1  (sys_clk)
);

ms72xx_ctl ms72xx_ctl(
    .clk        (cfg_clk),
    .rst_n      (rstn_out),
    .init_over_rx(rx_init_done),
    .init_over  (init_over),
    .iic_scl    (hd_scl),
    .iic_sda    (hd_sda)
);

always @(posedge cfg_clk) begin
    if(!locked)
        rstn_1ms <= 16'd0;
    else if(rstn_1ms == 16'h2710)
        rstn_1ms <= rstn_1ms;
    else
        rstn_1ms <= rstn_1ms + 1'b1;
end

assign rstn_out  = (rstn_1ms == 16'h2710);
assign rx_rst_n  = rstn_out;

// =====================================================================
// ���ؼ��������ź�ȫ��ʹ�ã��������գ�
// =====================================================================
assign pixclk_out      = pixclk_in;
assign vs_out          = vs_in;
assign hs_out          = hs_in;
assign de_out          = de_in;
assign pixel_16bit_out = {r_in[7:3], g_in[7:2], b_in[7:3]};

endmodule