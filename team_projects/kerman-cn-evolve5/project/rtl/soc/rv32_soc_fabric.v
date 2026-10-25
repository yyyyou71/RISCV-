`timescale 1ns/1ps
module rv32_soc_fabric #(
    parameter integer BURST_INTERFACE=0, FIRST_WAIT=0, BEAT_GAP=0,
    parameter integer MONITOR_ENABLE=0,CACHE_BYTES=1024,LINE_BYTES=16,CACHE_SETS=32,BP_ENTRIES=32,
    parameter [31:0] HW_CONFIG=0,
    parameter integer CLOCK_HZ = 50000000,
    parameter integer BAUD = 115200,
    parameter integer ROM_BYTES = 32768,
    parameter integer RAM_BYTES = 32768,
    parameter ROM_FILE = "firmware_rom.hex"
) (
    input wire clk, rst,
    input wire iv,
    input wire [31:0] ia,
    output wire ir,
    output wire [31:0] idata,
    output wire ie,
    input wire dv, dw,
    input wire [31:0] da, wd,
    input wire [3:0] ws,
    output reg dr,
    output reg [31:0] rdata,
    output reg de,
    input wire uart_rx,
    output wire uart_tx,
    input wire [7:0] gpio_in,
    output wire [7:0] gpio_out, gpio_oe,
    output wire timer_pending,
    input wire b_cmd_valid,b_cmd_write,b_cmd_instr,
    input wire [31:0] b_cmd_addr,b_cmd_wdata,
    input wire [3:0] b_cmd_wstrb,
    input wire [7:0] b_cmd_len,
    output wire b_cmd_ready,
    output wire b_rsp_valid,b_rsp_error,b_rsp_last,
    output wire [31:0] b_rsp_data,
    input wire b_rsp_ready,
    input wire [319:0] monitor_counts
);
    reg active,to_memory,periph_done,saved_write,saved_error;
    reg [31:0] saved_address,saved_wdata,saved_rdata;
    reg [3:0] saved_strobes;
    wire memory_command=b_cmd_instr || b_cmd_len!=0 || b_cmd_addr<ROM_BYTES ||
                        (b_cmd_addr>=32'h20000000 && b_cmd_addr<32'h20000000+RAM_BYTES);
    wire mc_ready,mr_valid,mr_error,mr_last; wire [31:0] mr_data;
    wire pv=BURST_INTERFACE ? (active && !to_memory && !periph_done) : dv;
    wire pw=BURST_INTERFACE ? saved_write : dw;
    wire [31:0] pa=BURST_INTERFACE ? saved_address : da;
    wire [31:0] pd=BURST_INTERFACE ? saved_wdata : wd;
    wire [3:0] ps=BURST_INTERFACE ? saved_strobes : ws;
    wire mem_select=pa<ROM_BYTES || (pa>=32'h20000000 && pa<32'h20000000+RAM_BYTES);
    wire uart_select=pa[31:12]==20'h40000;
    wire gpio_select=pa[31:12]==20'h40001;
    wire timer_select=pa[31:12]==20'h40002;
    wire monitor_select=MONITOR_ENABLE && pa[31:12]==20'h40003;
    wire mon_ready,mon_error; wire [31:0] mon_data;
    rv32_monitor #(.ENABLE(MONITOR_ENABLE),.CLOCK_HZ(CLOCK_HZ),.CACHE_BYTES(CACHE_BYTES),.LINE_BYTES(LINE_BYTES),.SETS(CACHE_SETS),
        .BP_ENTRIES(BP_ENTRIES),.CONFIG(HW_CONFIG),.FIRST_WAIT(FIRST_WAIT),.BEAT_GAP(BEAT_GAP)) monitor (
        .clk(clk),.rst(rst),.valid(pv && monitor_select),.write(pw),.addr(pa[11:0]),.wdata(pd),.wstrb(ps),
        .live_counts(monitor_counts),.ready(mon_ready),.error(mon_error),.rdata(mon_data));
    reg p_ready,p_error; reg [31:0] p_data;
    assign b_cmd_ready=BURST_INTERFACE && !rst && !active && (!memory_command || mc_ready);
    assign b_rsp_valid=BURST_INTERFACE && !rst && active && (to_memory?mr_valid:periph_done);
    assign b_rsp_data=to_memory?mr_data:saved_rdata;
    assign b_rsp_error=to_memory?mr_error:saved_error;
    assign b_rsp_last=to_memory?mr_last:1'b1;
    always @(posedge clk) begin
        if(rst) begin active<=0; to_memory<=0; periph_done<=0; saved_write<=0; saved_error<=0; saved_address<=0; saved_wdata<=0; saved_rdata<=0; saved_strobes<=0; end
        else if(BURST_INTERFACE) begin
            if(b_cmd_valid && b_cmd_ready) begin
                active<=1; to_memory<=memory_command; periph_done<=0;
                saved_write<=b_cmd_write; saved_address<=b_cmd_addr; saved_wdata<=b_cmd_wdata; saved_strobes<=b_cmd_wstrb;
            end
            if(pv && p_ready) begin periph_done<=1; saved_error<=p_error; saved_rdata<=p_data; end
            if(b_rsp_valid && b_rsp_ready && b_rsp_last) active<=0;
        end
    end
    wire mr,me,ur,ue,gr,ge,tr,te;
    wire [31:0] md,ud,gd,td;
    rv32_soc_memory #(.BURST_INTERFACE(BURST_INTERFACE),.FIRST_WAIT(FIRST_WAIT),.BEAT_GAP(BEAT_GAP),.ROM_BYTES(ROM_BYTES),.RAM_BYTES(RAM_BYTES),.ROM_FILE(ROM_FILE)) memory (
        .clk(clk),.rst(rst),.iv(iv),.ia(ia),.ir(ir),.idata(idata),.ie(ie),
        .dv(!BURST_INTERFACE && dv && mem_select),.dw(dw),.da(da),.wd(wd),.ws(ws),.dr(mr),.rdata(md),.de(me),
        .b_cmd_valid(BURST_INTERFACE && !active && b_cmd_valid && memory_command),.b_cmd_ready(mc_ready),
        .b_cmd_write(b_cmd_write),.b_cmd_instr(b_cmd_instr),.b_cmd_addr(b_cmd_addr),.b_cmd_wdata(b_cmd_wdata),.b_cmd_wstrb(b_cmd_wstrb),.b_cmd_len(b_cmd_len),
        .b_rsp_valid(mr_valid),.b_rsp_ready(active && to_memory && b_rsp_ready),.b_rsp_data(mr_data),.b_rsp_error(mr_error),.b_rsp_last(mr_last)
    );
    rv32_uart #(.CLOCK_HZ(CLOCK_HZ),.BAUD(BAUD)) uart (
        .clk(clk),.rst(rst),.valid(pv && uart_select),.write(pw),.addr(pa[11:0]),
        .wdata(pd),.wstrb(ps),.ready(ur),.rdata(ud),.error(ue),.rx(uart_rx),.tx(uart_tx)
    );
    rv32_gpio gpio (
        .clk(clk),.rst(rst),.valid(pv && gpio_select),.write(pw),.addr(pa[11:0]),
        .wdata(pd),.wstrb(ps),.ready(gr),.rdata(gd),.error(ge),
        .pins_in(gpio_in),.pins_out(gpio_out),.pins_oe(gpio_oe)
    );
    rv32_timer timer (
        .clk(clk),.rst(rst),.valid(pv && timer_select),.write(pw),.addr(pa[11:0]),
        .wdata(pd),.wstrb(ps),.ready(tr),.rdata(td),.error(te),.pending(timer_pending)
    );
    always @* begin
        p_ready=pv; p_data=0; p_error=pv;
        if(!BURST_INTERFACE && mem_select) begin p_ready=mr; p_data=md; p_error=me; end
        else if(uart_select) begin p_ready=ur; p_data=ud; p_error=ue; end
        else if(gpio_select) begin p_ready=gr; p_data=gd; p_error=ge; end
        else if(timer_select) begin p_ready=tr; p_data=td; p_error=te; end
        else if(monitor_select) begin p_ready=mon_ready; p_data=mon_data; p_error=mon_error; end
        dr=BURST_INTERFACE?1'b0:p_ready; rdata=p_data; de=p_error;
    end
endmodule
