`timescale 1ns/1ps

module memory_core #(
    // 仿真初始化文件按字节存放；留空时保持未初始化的 X。
    parameter INIT_FILE = "",
    parameter DUAL_IMAGE = 0
)(
    // 单端口 RAM：14 位字地址，16384 x 32 bit，共 64 KiB。
    input [13:0]a_addr,
    input [31:0]a_wr_data,
    input a_wr_en,
    input [3:0]a_wr_byte_en,
    input a_clk,
    input a_rst,  // 高电平同步复位，只清输出，不清 RAM；复位时禁止写入。
    output reg[31:0]a_rd_data

);
    // 小端排列：byte_en[0] 对应 wr_data[7:0]，byte_en[3] 对应 [31:24]。
    // 未提供初始化文件时保持 X；复位不改变存储内容。
    reg [7:0]memory[0:65535];
    integer byte_lane;
    integer init_byte;

    initial begin
        if(INIT_FILE != "") begin
            for(init_byte = 0; init_byte < 65536; init_byte = init_byte + 1)
                memory[init_byte] = 8'b0;
            $readmemh(INIT_FILE, memory, 0);
        end
    end

    always @(posedge a_clk) begin
        if(a_rst)begin
            a_rd_data <= 32'b0;
        end
        
        else begin
            for(byte_lane = 0; byte_lane < 4; byte_lane = byte_lane + 1) begin
                if(a_wr_en && a_wr_byte_en[byte_lane]) begin
                    memory[{a_addr, byte_lane[1:0]}] <= a_wr_data[byte_lane*8 +: 8];
                    // Transparent_Write：同一上升沿写入并输出新字节。
                    a_rd_data[byte_lane*8 +: 8] <= a_wr_data[byte_lane*8 +: 8];
                end
                else begin
                    // 没有读使能端口，每拍都读取；未写字节输出原值。
                    a_rd_data[byte_lane*8 +: 8] <= memory[{a_addr, byte_lane[1:0]}];
                end
            end
        end
    end

endmodule
