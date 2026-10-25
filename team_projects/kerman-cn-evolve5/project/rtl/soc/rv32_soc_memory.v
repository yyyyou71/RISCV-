`timescale 1ns/1ps
// Clocked ROM/RAM reads, one outstanding request per CPU port.
// Instruction ROM holds one tagged sequential lookahead word. A matching
// request completes immediately; a miss performs a normal synchronous read.
// Lookahead is ROM-only and never issues MMIO accesses or architectural faults.
// A store takes effect only on valid && ready, never at request capture.
// RAM has no hardware reset loop. crt0 initializes .data/.bss in software.
module rv32_soc_memory #(
    parameter integer BURST_INTERFACE=0, FIRST_WAIT=0, BEAT_GAP=0,
    parameter integer ROM_BYTES = 32768,
    parameter integer RAM_BYTES = 32768,
    parameter [31:0] RAM_BASE = 32'h20000000,
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
    output wire [31:0] rdata,
    output reg de,
    input wire b_cmd_valid,b_cmd_write,b_cmd_instr,
    input wire [31:0] b_cmd_addr,b_cmd_wdata,
    input wire [3:0] b_cmd_wstrb,
    input wire [7:0] b_cmd_len,
    output wire b_cmd_ready,
    output wire b_rsp_valid,b_rsp_error,b_rsp_last,
    output wire [31:0] b_rsp_data,
    input wire b_rsp_ready
);
    reg [31:0] rom [0:ROM_BYTES/4-1] /* synthesis syn_romstyle="block_rom" */;
    reg [31:0] ram [0:RAM_BYTES/4-1] /* synthesis syn_ramstyle="block_ram" */;
    reg [31:0] rom_iq, rom_dq, ram_dq;
    reg i_data_valid, d_rom_q, d_ram_q;
    reg i_word_valid;
    reg [31:0] i_word_addr;
    wire i_hit=i_word_valid && i_word_addr==ia;
    wire [31:0] i_read_addr=i_hit ? ia+32'd4 : ia;
    wire i_read_legal=i_read_addr < ROM_BYTES && i_read_addr[1:0]==0;
    wire d_rom = da < ROM_BYTES;
    wire d_ram = da >= RAM_BASE && da < RAM_BASE + RAM_BYTES;
    wire [31:0] ram_index = (da - RAM_BASE) >> 2;
    integer lane;
    assign ir=!rst && iv && i_hit;
    assign ie=i_word_valid && !i_data_valid;
    assign idata = i_data_valid ? rom_iq : 32'b0;
    assign rdata = de ? 32'b0 : d_rom_q ? rom_dq : d_ram_q ? ram_dq : 32'b0;
    initial begin
        if (ROM_FILE != "") $readmemh(ROM_FILE,rom);
    end
    generate if(!BURST_INTERFACE) begin: scalar_memory
        assign b_cmd_ready=0; assign b_rsp_valid=0; assign b_rsp_data=0; assign b_rsp_error=0; assign b_rsp_last=0;
    // Separate clocked data paths without output reset/mux feedback. This is
    // the intended DRM-inference template; actual device mapping still needs PDS.
    always @(posedge clk) begin
        if (!rst && iv && i_read_legal)
            rom_iq <= rom[i_read_addr >> 2];
        if (!rst && !dr && dv && d_rom && !dw)
            rom_dq <= rom[da >> 2];
        if (!rst && !dr && dv && d_ram)
            ram_dq <= ram[ram_index];
        if (!rst && dr && dv && dw && !de && d_ram)
            for (lane = 0; lane < 4; lane = lane + 1)
                if (ws[lane]) ram[ram_index][8*lane +: 8] <= wd[8*lane +: 8];
    end
    always @(posedge clk) begin
        if (rst) begin
            i_word_valid <= 0; i_word_addr <= 0; i_data_valid <= 0;
            dr <= 0; d_rom_q <= 0; d_ram_q <= 0; de <= 0;
        end else begin
            if (iv) begin
                i_word_valid <= 1;
                i_word_addr <= i_read_addr;
                i_data_valid <= i_read_legal;
            end
            if (dr) begin
                dr <= 0;
            end else if (dv) begin
                dr <= 1;
                de <= (!d_rom && !d_ram) || (dw && d_rom);
                d_ram_q <= d_ram;
                d_rom_q <= d_rom && !dw;
            end
        end
    end
    end else begin: burst_memory

        localparam B_IDLE=0,B_WAIT=1,B_RESP=2;
        reg [1:0] b_state;
        reg [31:0] address,write_data;
        reg [3:0] strobes;
        reg [7:0] length,beat;
        reg write_op,instruction,command_bad,beat_error,rom_sel,ram_sel;
        reg [31:0] rom_bq,ram_bq;
        integer delay_count,b_lane;
        wire accept=b_cmd_valid && b_cmd_ready;
        wire advance=b_rsp_valid && b_rsp_ready && !b_rsp_last;
        wire [31:0] load_address=accept ? b_cmd_addr : address+32'd4;
        wire load_write=accept ? b_cmd_write : write_op;
        wire load_instr=accept ? b_cmd_instr : instruction;
        wire [32:0] command_end={1'b0,b_cmd_addr}+({25'b0,b_cmd_len}<<2);
        wire bad_command=(b_cmd_write && b_cmd_len!=0) || (b_cmd_len!=0 && b_cmd_addr[1:0]!=0) || command_end[32];
        wire load_bad=accept ? bad_command : command_bad;
        wire load_rom=load_address<ROM_BYTES;
        wire load_ram=load_address>=RAM_BASE && load_address<RAM_BASE+RAM_BYTES;
        wire legal=load_instr ? (load_rom && !load_write && load_address[1:0]==0) :
                                ((load_rom && !load_write) || load_ram);
        assign b_cmd_ready=!rst && b_state==B_IDLE;
        assign b_rsp_valid=!rst && b_state==B_RESP;
        assign b_rsp_error=beat_error;
        assign b_rsp_last=beat==length;
        assign b_rsp_data=beat_error || write_op ? 32'b0 : rom_sel ? rom_bq : ram_sel ? ram_bq : 32'b0;
        // One synchronous read per accepted beat. A ready consumer can receive
        // consecutive words on consecutive cycles after the initial latency.
        always @(posedge clk) begin
            if(!rst && (accept || advance) && legal && !load_bad && !load_write) begin
                if(load_rom) rom_bq<=rom[load_address>>2];
                if(load_ram) ram_bq<=ram[(load_address-RAM_BASE)>>2];
            end
            if(!rst && b_rsp_valid && b_rsp_ready && write_op && !beat_error)
                for(b_lane=0;b_lane<4;b_lane=b_lane+1) if(strobes[b_lane])
                    ram[(address-RAM_BASE)>>2][8*b_lane+:8]<=write_data[8*b_lane+:8];
        end
        always @(posedge clk) begin
            dr<=0; de<=0;
            if(rst) begin
                b_state<=B_IDLE; address<=0; write_data<=0; strobes<=0; length<=0; beat<=0;
                write_op<=0; instruction<=0; command_bad<=0; beat_error<=0; rom_sel<=0; ram_sel<=0; delay_count<=0;
            end else begin
                if(accept || advance) begin
                    beat_error<=load_bad || !legal; rom_sel<=load_rom; ram_sel<=load_ram;
                end
                if(accept) begin
                    address<=b_cmd_addr; write_data<=b_cmd_wdata; strobes<=b_cmd_wstrb;
                    length<=b_cmd_len; beat<=0; write_op<=b_cmd_write; instruction<=b_cmd_instr; command_bad<=bad_command;
                    delay_count<=FIRST_WAIT; b_state<=FIRST_WAIT==0 ? B_RESP : B_WAIT;
                end else if(b_state==B_WAIT) begin
                    if(delay_count<=1) b_state<=B_RESP;
                    else delay_count<=delay_count-1;
                end else if(b_rsp_valid && b_rsp_ready) begin
                    if(b_rsp_last) b_state<=B_IDLE;
                    else begin
                        address<=address+32'd4; beat<=beat+1'b1;
                        delay_count<=BEAT_GAP; b_state<=BEAT_GAP==0 ? B_RESP : B_WAIT;
                    end
                end
            end
        end
    end endgenerate
endmodule
