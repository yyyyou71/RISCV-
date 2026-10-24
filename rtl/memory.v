`timescale 1ns/1ps

`ifndef DATA_FILE
    `define DATA_FILE "data_test.data"
`endif

// CPU 字节地址接口与 16384 x 32 bit 单端口 RAM 之间的适配层。
module memory #(
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 16,
    parameter DEPTH = 1 << ADDR_WIDTH
) (
    input clk,
    input rst_n,

    input [1:0]MemSize, // 00=字节 01=半字 10=字
    input MemUnsigned,  // funct3 的 bit2 就是零扩展位（LBU/LHU=1）

    input wr_en,
    input [ADDR_WIDTH-1:0]wr_addr,
    input [31:0]wr_data,

    input rd_en,
    input [ADDR_WIDTH-1:0]rd_addr,
    output reg [31:0]rd_data
);

    wire [13:0] core_word_addr = wr_en ? wr_addr[15:2] : rd_addr[15:2];
    reg [3:0] core_byte_en;
    wire [31:0] core_wr_data = wr_data << {wr_addr[1:0], 3'b000};
    wire [31:0] core_rd_data;

    always @* begin
        case(MemSize)
            2'b00: core_byte_en = 4'b0001 << wr_addr[1:0];
            2'b01: core_byte_en = 4'b0011 << wr_addr[1:0];
            2'b10: core_byte_en = 4'b1111;
            default: core_byte_en = 4'b0000;
        endcase
    end

    memory_core #(
        .INIT_FILE(`DATA_FILE)
    ) u_memory_core (
        .a_addr(core_word_addr),
        .a_wr_data(core_wr_data),
        .a_wr_en(wr_en),
        .a_wr_byte_en(core_byte_en),
        .a_clk(clk),
        .a_rst(!rst_n),
        .a_rd_data(core_rd_data)
    );

    reg [1:0] rd_offset_q;
    reg [1:0] rd_size_q;
    reg rd_unsigned_q;
    reg rd_valid_q;
    reg [31:0] held_rd_data;
    wire [31:0] shifted_rd_data = core_rd_data >> {rd_offset_q, 3'b000};

    // 元信息和 RAM 读数据在同一上升沿锁存，输出扩展不再额外寄存一拍。
    // held_rd_data 保存上一次输出，使未读取的周期仍保持原接口的输出行为。
    always @(posedge clk) begin
        if(!rst_n) begin
            rd_offset_q <= 2'b0;
            rd_size_q <= 2'b0;
            rd_unsigned_q <= 1'b0;
            rd_valid_q <= 1'b0;
            held_rd_data <= 32'b0;
        end
        else begin
            rd_offset_q <= rd_addr[1:0];
            rd_size_q <= MemSize;
            rd_unsigned_q <= MemUnsigned;
            rd_valid_q <= rd_en && (MemSize != 2'b11);
            held_rd_data <= rd_data;
        end
    end

    always @* begin
        rd_data = held_rd_data;
        if(rd_valid_q) begin
            case(rd_size_q)
                2'b00: rd_data = {{24{!rd_unsigned_q && shifted_rd_data[7]}}, shifted_rd_data[7:0]};
                2'b01: rd_data = {{16{!rd_unsigned_q && shifted_rd_data[15]}}, shifted_rd_data[15:0]};
                2'b10: rd_data = shifted_rd_data;
                default: rd_data = held_rd_data;
            endcase
        end
    end

    // 当前 RAM IP 的固定容量，以及单端口单拍访问的约束。
    // synthesis translate_off
    initial begin
        if(DATA_WIDTH != 8 || ADDR_WIDTH != 16 || DEPTH != 65536)
            $fatal(1, "memory_core requires DATA_WIDTH=8, ADDR_WIDTH=16, DEPTH=65536");
    end

    always @(posedge clk) begin
        if(rst_n) begin
            if(wr_en && rd_en && wr_addr[ADDR_WIDTH-1:2] != rd_addr[ADDR_WIDTH-1:2])
                $fatal(1, "Single-port RAM cannot read and write different word addresses in one cycle");
            if((wr_en && ((MemSize == 2'b01 && wr_addr[1:0] == 2'b11) ||
                          (MemSize == 2'b10 && wr_addr[1:0] != 2'b00))) ||
               (rd_en && ((MemSize == 2'b01 && rd_addr[1:0] == 2'b11) ||
                          (MemSize == 2'b10 && rd_addr[1:0] != 2'b00))))
                $fatal(1, "Single-port RAM access crosses a word boundary");
        end
    end
    // synthesis translate_on
endmodule
