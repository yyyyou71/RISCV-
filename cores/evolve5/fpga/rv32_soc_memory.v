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
    output wire dr,
    output wire [31:0] rdata,
    output wire de,
    input wire b_cmd_valid,b_cmd_write,b_cmd_instr,
    input wire [31:0] b_cmd_addr,b_cmd_wdata,
    input wire [3:0] b_cmd_wstrb,
    input wire [7:0] b_cmd_len,
    output wire b_cmd_ready,
    output wire b_rsp_valid,b_rsp_error,b_rsp_last,
    output wire [31:0] b_rsp_data,
    input wire b_rsp_ready
);

    localparam IDLE=0, WAIT_STATE=1, RESPONSE=2;
    reg [1:0] state;
    reg [31:0] address, write_data;
    reg [3:0] strobes;
    reg [7:0] length, beat;
    reg write_op, instruction, command_bad, beat_error, rom_selected, ram_selected;
    integer delay_count;
    wire accept = b_cmd_valid && b_cmd_ready;
    wire advance = b_rsp_valid && b_rsp_ready && !b_rsp_last;
    wire [31:0] load_address = accept ? b_cmd_addr : address + 32'd4;
    wire [31:0] memory_address = accept || advance ? load_address : address;
    wire load_write = accept ? b_cmd_write : write_op;
    wire load_instruction = accept ? b_cmd_instr : instruction;
    wire [32:0] command_end = {1'b0,b_cmd_addr} + ({25'b0,b_cmd_len} << 2);
    wire bad_command = (b_cmd_write && b_cmd_len != 0) ||
                       (b_cmd_len != 0 && b_cmd_addr[1:0] != 0) || command_end[32];
    wire load_bad = accept ? bad_command : command_bad;
    wire load_rom = load_address < ROM_BYTES;
    wire load_ram = load_address >= RAM_BASE && load_address < RAM_BASE + RAM_BYTES;
    wire legal = load_instruction ? (load_rom && !load_write && load_address[1:0] == 0) :
                                   ((load_rom && !load_write) || load_ram);
    wire [31:0] rom_data, ram_data;
    wire ram_write = !rst && b_rsp_valid && b_rsp_ready && write_op && !beat_error && ram_selected;

    assign ir = 0;
    assign idata = 0;
    assign ie = 0;
    assign dr = 0;
    assign rdata = 0;
    assign de = 0;
    assign b_cmd_ready = !rst && state == IDLE;
    assign b_rsp_valid = !rst && state == RESPONSE;
    assign b_rsp_error = beat_error;
    assign b_rsp_last = beat == length;
    assign b_rsp_data = beat_error || write_op ? 32'b0 :
                        rom_selected ? rom_data : ram_selected ? ram_data : 32'b0;

    pango_evolve_rom rom (
        .clk(clk), .rst(rst), .addr(memory_address[14:2]),
        .addr_strobe(1'b0), .rd_data(rom_data)
    );
    pango_evolve_ram ram (
        .a_clk(clk), .a_rst(rst), .a_addr(memory_address[14:2]), .a_wr_en(ram_write),
        .a_wr_byte_en(strobes), .a_wr_data(write_data), .a_rd_data(ram_data),
        .b_clk(clk), .b_rst(rst), .b_addr(13'b0), .b_wr_en(1'b0),
        .b_wr_byte_en(4'b0), .b_wr_data(32'b0), .b_rd_data()
    );

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            address <= 0; write_data <= 0; strobes <= 0; length <= 0; beat <= 0;
            write_op <= 0; instruction <= 0; command_bad <= 0;
            beat_error <= 0; rom_selected <= 0; ram_selected <= 0; delay_count <= 0;
        end else begin
            if (accept || advance) begin
                beat_error <= load_bad || !legal;
                rom_selected <= load_rom;
                ram_selected <= load_ram;
            end
            if (accept) begin
                address <= b_cmd_addr; write_data <= b_cmd_wdata; strobes <= b_cmd_wstrb;
                length <= b_cmd_len; beat <= 0; write_op <= b_cmd_write;
                instruction <= b_cmd_instr; command_bad <= bad_command;
                delay_count <= FIRST_WAIT;
                state <= FIRST_WAIT == 0 ? RESPONSE : WAIT_STATE;
            end else if (state == WAIT_STATE) begin
                if (delay_count <= 1) state <= RESPONSE;
                else delay_count <= delay_count - 1;
            end else if (b_rsp_valid && b_rsp_ready) begin
                if (b_rsp_last) state <= IDLE;
                else begin
                    address <= address + 32'd4;
                    beat <= beat + 1'b1;
                    delay_count <= BEAT_GAP;
                    state <= BEAT_GAP == 0 ? RESPONSE : WAIT_STATE;
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (!BURST_INTERFACE || ROM_BYTES != 32768 || RAM_BYTES != 32768 || RAM_BASE != 32'h20000000)
            $fatal(1, "EVOLVE5 FPGA adapter requires the 32 KiB burst memory configuration");
    end
`endif
endmodule
