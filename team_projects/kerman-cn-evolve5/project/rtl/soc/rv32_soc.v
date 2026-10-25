`timescale 1ns/1ps
// Board-independent SoC top. clk/rst must already be conditioned by a board wrapper.
module rv32_soc #(
    parameter integer CLOCK_HZ = 50000000,
    parameter integer BAUD = 115200,
    parameter integer M_ENABLE=0,
    parameter integer BP_ENABLE=1,
    parameter integer BP_INDEX_BITS=5,
    parameter integer GSHARE_ENABLE=0, PHT_BITS=8, RAS_DEPTH=0, FETCH_DEPTH=1, FETCH_BYPASS=0, LOAD_FORWARD=0,
    parameter integer DUAL_ENABLE=0, WIDE_FETCH=0, PAIR_BRANCH=0, PAIR_MEMORY=0, PAIR_JALR=0, FAST_MUL=0, FAST_STORE=0, PAIR_MUL=0,
    parameter integer BURST_BACKEND=1, BURST_FILL=1, MEM_FIRST_WAIT=0, MEM_BEAT_GAP=0,
    parameter integer ICACHE_ENABLE=1,
    parameter integer DCACHE_ENABLE=1,
    parameter integer CACHE_SET_BITS=5,
    parameter integer CACHE_LINE_WORD_BITS=2,
    parameter [31:0] RESET_MTVEC=0,
    parameter ROM_FILE = "firmware_rom.hex"
) (
    input wire clk, rst,
    input wire uart_rx,
    output wire uart_tx,
    input wire [7:0] gpio_in,
    output wire [7:0] gpio_out, gpio_oe,
    output wire timer_pending,
    output wire halted,
    output wire [31:0] trap_pc, trap_cause, trap_tval,
    output wire debug_commit, debug_trap,
    output wire [31:0] debug_pc, debug_insn
);
    wire iv,ir,ie,dv,dw,dr,de;
    wire [31:0] ia,idata,da,wd,rdata,idata_second;
    wire i_second_valid;
    wire [3:0] ws;
    wire biv,bir,bie,bdv,bdw,bdr,bde;
    wire [31:0] bia,bidata,bda,bwd,brdata;
    wire [3:0] bws;
    wire icv,icr,icw,irv,irr,ire,irl,dcv,dcr,dcw,drv,drr,dre,drl;
    wire [31:0] ica,icd,ird,dca,dcd,drd; wire [3:0] ics,dcs; wire [7:0] icl,dcl;
    wire cv,cr,cw,ci,rv,rr,re,rl; wire [31:0] ca,cd,rd; wire [3:0] cs; wire [7:0] cl;
    wire [31:0] ih,im,dh,dm,wh,wm;
    reg [31:0] read_commands,burst_commands,read_beats,write_responses;
    reg monitor_memory,monitor_write;
    wire command_memory=ca<32'h8000 || (ca>=32'h20000000 && ca<32'h20008000);
    wire [319:0] monitor_counts={write_responses,read_beats,burst_commands,read_commands,wm,wh,dm,dh,im,ih};
    localparam [31:0] HARDWARE_CONFIG=(M_ENABLE<<5)|(BP_ENABLE<<4)|(BURST_FILL<<3)|(BURST_BACKEND<<2)|(DCACHE_ENABLE<<1)|ICACHE_ENABLE;
    always @(posedge clk) begin
        if(rst) begin read_commands<=0; burst_commands<=0; read_beats<=0; write_responses<=0; monitor_memory<=0; monitor_write<=0; end
        else begin
            if(cv && cr) begin
                monitor_memory<=command_memory; monitor_write<=cw;
                if(command_memory && !cw) begin
                    read_commands<=read_commands+1;
                    if(cl!=0) burst_commands<=burst_commands+1;
                end
            end
            if(rv && rr && monitor_memory) begin
                if(monitor_write) write_responses<=write_responses+1;
                else read_beats<=read_beats+1;
            end
        end
    end

    rv32_core #(.RESET_MTVEC(RESET_MTVEC),.M_ENABLE(M_ENABLE),.BP_ENABLE(BP_ENABLE),.BP_INDEX_BITS(BP_INDEX_BITS),.GSHARE_ENABLE(GSHARE_ENABLE),.PHT_BITS(PHT_BITS),.RAS_DEPTH(RAS_DEPTH),.FETCH_DEPTH(FETCH_DEPTH),.FETCH_BYPASS(FETCH_BYPASS),.LOAD_FORWARD(LOAD_FORWARD),.DUAL_ENABLE(DUAL_ENABLE),.WIDE_FETCH(WIDE_FETCH),.PAIR_BRANCH(PAIR_BRANCH),.PAIR_MEMORY(PAIR_MEMORY),.PAIR_JALR(PAIR_JALR),.FAST_MUL(FAST_MUL),.FAST_STORE(FAST_STORE),.PAIR_MUL(PAIR_MUL)) cpu (
        .clk(clk),.rst(rst),.irq_timer(timer_pending),.interrupt_taken(),.imem_valid(iv),.imem_addr(ia),.imem_ready(ir),.imem_rdata(idata),.imem_error(ie),.imem_second_valid(i_second_valid),.imem_second_error(1'b0),.imem_rdata_second(idata_second),
        .dmem_valid(dv),.dmem_write(dw),.dmem_addr(da),.dmem_wdata(wd),.dmem_wstrb(ws),
        .dmem_ready(dr),.dmem_rdata(rdata),.dmem_error(de),
        .halted(halted),.trap_pc(trap_pc),.trap_cause(trap_cause),.trap_tval(trap_tval),
        .retire_valid(debug_commit),.retire_trap(debug_trap),.retire_pc(debug_pc),.retire_insn(debug_insn),
        .retire_rd_we(),.retire_next_pc(),.retire_rd(),.retire_rd_data(),
        .retire_mem_addr(),.retire_mem_wdata(),.retire_mem_rdata(),.retire_mem_wmask(),.retire_mem_rmask(),
        .retire_cause(),.retire_tval(),.cycles(),.instret(),.load_stall_cycles(),.data_wait_cycles(),.fetch_wait_cycles(),.redirect_count()
    );
    rv32_icache #(.WIDE_FETCH(WIDE_FETCH),.BURST_INTERFACE(BURST_BACKEND),.BURST_FILL(BURST_FILL),.ENABLE(ICACHE_ENABLE),.SET_BITS(CACHE_SET_BITS),.LINE_WORD_BITS(CACHE_LINE_WORD_BITS)) i_cache (
        .clk(clk),.rst(rst),.valid(iv),.addr(ia),.ready(ir),.rdata(idata),.error(ie),.second_valid(i_second_valid),.rdata_second(idata_second),
        .mem_valid(biv),.mem_addr(bia),.mem_ready(bir),.mem_rdata(bidata),.mem_error(bie),
        .cmd_valid(icv),.cmd_ready(icr),.cmd_write(icw),.cmd_addr(ica),.cmd_wdata(icd),.cmd_wstrb(ics),.cmd_len(icl),
        .rsp_valid(irv),.rsp_ready(irr),.rsp_data(ird),.rsp_error(ire),.rsp_last(irl),
        .read_hits(ih),.read_misses(im),.refill_words(),.refill_errors());
    rv32_dcache #(.FAST_STORE(FAST_STORE),.BURST_INTERFACE(BURST_BACKEND),.BURST_FILL(BURST_FILL),.ENABLE(DCACHE_ENABLE),.SET_BITS(CACHE_SET_BITS),.LINE_WORD_BITS(CACHE_LINE_WORD_BITS)) d_cache (
        .clk(clk),.rst(rst),.valid(dv),.write(dw),.addr(da),.wdata(wd),.wstrb(ws),.ready(dr),.rdata(rdata),.error(de),
        .mem_valid(bdv),.mem_write(bdw),.mem_addr(bda),.mem_wdata(bwd),.mem_wstrb(bws),.mem_ready(bdr),.mem_rdata(brdata),.mem_error(bde),
        .cmd_valid(dcv),.cmd_ready(dcr),.cmd_write(dcw),.cmd_addr(dca),.cmd_wdata(dcd),.cmd_wstrb(dcs),.cmd_len(dcl),
        .rsp_valid(drv),.rsp_ready(drr),.rsp_data(drd),.rsp_error(dre),.rsp_last(drl),
        .read_hits(dh),.read_misses(dm),.write_hits(wh),.write_misses(wm),.bypass_requests(),.refill_words(),.refill_errors());
    rv32_burst_arbiter arbiter (
        .clk(clk),.rst(rst),.i_valid(icv),.i_ready(icr),.i_write(icw),.i_addr(ica),.i_wdata(icd),.i_wstrb(ics),.i_len(icl),
        .i_rsp_valid(irv),.i_rsp_ready(irr),.i_rsp_data(ird),.i_rsp_error(ire),.i_rsp_last(irl),
        .d_valid(dcv),.d_ready(dcr),.d_write(dcw),.d_addr(dca),.d_wdata(dcd),.d_wstrb(dcs),.d_len(dcl),
        .d_rsp_valid(drv),.d_rsp_ready(drr),.d_rsp_data(drd),.d_rsp_error(dre),.d_rsp_last(drl),
        .cmd_valid(cv),.cmd_ready(cr),.cmd_write(cw),.cmd_instr(ci),.cmd_addr(ca),.cmd_wdata(cd),.cmd_wstrb(cs),.cmd_len(cl),
        .rsp_valid(rv),.rsp_ready(rr),.rsp_data(rd),.rsp_error(re),.rsp_last(rl));
    rv32_soc_fabric #(.MONITOR_ENABLE(1),.HW_CONFIG(HARDWARE_CONFIG),.CACHE_BYTES(2*(1<<CACHE_SET_BITS)*(4<<CACHE_LINE_WORD_BITS)),
        .LINE_BYTES(4<<CACHE_LINE_WORD_BITS),.CACHE_SETS(1<<CACHE_SET_BITS),.BP_ENTRIES(1<<BP_INDEX_BITS),
        .BURST_INTERFACE(BURST_BACKEND),.FIRST_WAIT(MEM_FIRST_WAIT),.BEAT_GAP(MEM_BEAT_GAP),.CLOCK_HZ(CLOCK_HZ),.BAUD(BAUD),.ROM_FILE(ROM_FILE)) fabric (
        .clk(clk),.rst(rst),.iv(biv),.ia(bia),.ir(bir),.idata(bidata),.ie(bie),
        .dv(bdv),.dw(bdw),.da(bda),.wd(bwd),.ws(bws),.dr(bdr),.rdata(brdata),.de(bde),
        .b_cmd_valid(cv),.b_cmd_ready(cr),.b_cmd_write(cw),.b_cmd_instr(ci),.b_cmd_addr(ca),.b_cmd_wdata(cd),.b_cmd_wstrb(cs),.b_cmd_len(cl),
        .b_rsp_valid(rv),.b_rsp_ready(rr),.b_rsp_data(rd),.b_rsp_error(re),.b_rsp_last(rl),
        .monitor_counts(monitor_counts),
        .uart_rx(uart_rx),.uart_tx(uart_tx),.gpio_in(gpio_in),.gpio_out(gpio_out),.gpio_oe(gpio_oe),.timer_pending(timer_pending)
    );
endmodule
