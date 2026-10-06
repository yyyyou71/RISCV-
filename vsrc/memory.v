`ifndef DATA_FILE
    `define DATA_FILE "data_test.data"
`endif

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

    integer i;
    reg [DATA_WIDTH-1:0]mem[0 : DEPTH-1];

    // 初始化加载全局变量
    initial begin
        for(i=0;i < DEPTH ; i++)begin
            mem[i]=0;
        end
        $readmemh(`DATA_FILE,mem,16'h1000);  /* ← 第三个参数：起始下标 */
    end

    always @(posedge clk) begin

        // 复位只清理输出寄存器
        if(!rst_n)begin
            rd_data <= 0;
        end

        else begin
            case ({wr_en,rd_en})
                2'b10: begin    // 只写
                    case (MemSize)
                        2'b00:begin
                            mem[wr_addr] <= wr_data[7:0];
                        end 
                        2'b01:begin
                            mem[wr_addr] <= wr_data[7:0];
                            mem[wr_addr + 1] <= wr_data[15:8];
                        end
                        2'b10:begin
                            mem[wr_addr] <= wr_data[7:0];
                            mem[wr_addr + 1] <= wr_data[15:8];
                            mem[wr_addr + 2] <= wr_data[23:16];
                            mem[wr_addr + 3] <= wr_data[31:24];                             
                        end
                        default:begin
                            // 什么也不做？
                        end
                    endcase
                end
                2'b01: begin    // 只读
                    case ({MemUnsigned,MemSize})
                        3'b000:begin    // 读字节(符号位扩展)  
                            rd_data <= {{24{mem[rd_addr][7]}},mem[rd_addr]};
                        end
                        3'b001:begin    // 读半字(符号位扩展)
                            rd_data <= {{16{mem[rd_addr + 1][7]}},mem[rd_addr + 1],mem[rd_addr]};
                        end
                        3'b010:begin    // 读整字
                            rd_data <= {mem[rd_addr + 3],mem[rd_addr + 2],mem[rd_addr + 1],mem[rd_addr]};
                        end
                        3'b100:begin    // 读字节(零扩展)
                            rd_data <= {24'b0,mem[rd_addr]};
                        end
                        3'b101:begin    // 读半字(零扩展)
                            rd_data <= {16'b0,mem[rd_addr + 1],mem[rd_addr]};
                        end
                        default:begin
                            
                        end
                    endcase
                end
                2'b11: begin    // 如果读写同时拉高，那么只读，不过大概率不会出现这种情况
                    case ({MemUnsigned,MemSize})
                        3'b000:begin    // 读字节(符号位扩展)  
                            rd_data <= {{24{mem[rd_addr][7]}},mem[rd_addr]};
                        end
                        3'b001:begin    // 读半字(符号位扩展)
                            rd_data <= {{16{mem[rd_addr + 1][7]}},mem[rd_addr + 1],mem[rd_addr]};
                        end
                        3'b010:begin    // 读整字
                            rd_data <= {mem[rd_addr + 3],mem[rd_addr + 2],mem[rd_addr + 1],mem[rd_addr]};
                        end
                        3'b100:begin    // 读字节(零扩展)
                            rd_data <= {24'b0,mem[rd_addr]};
                        end
                        3'b101:begin    // 读半字(零扩展)
                            rd_data <= {16'b0,mem[rd_addr + 1],mem[rd_addr]};
                        end
                        default:begin
                            
                        end
                    endcase 
                end
                default: begin  // 其他，同样大概率不会出现这个情况
                    
                end
            endcase
        end
    end

endmodule
