module Acore(
    input clk,
    input rst_n

);
    //--------------------variable------------------
    // state1-IF
    wire [31:0]pc;
    wire [31:0]instruction;
    wire load_pc_en;
    wire [31:0]load_pc;
    wire stall_IF;
    wire flush_IF;
    wire valid_in_IF;
    wire valid_out_IF;

    // stage2-ID
    wire valid_in_ID;
    wire flush_ID;
    wire stall_ID;
    wire [4:0]rs1_addr_ID;
    wire [4:0]rs2_addr_ID;
    wire [4:0]rd_addr_ID;
    wire RegWrite_ID;
    wire MemRead_ID;
    wire MemWrite_ID;
    wire [1:0]MemSize_ID;
    wire MemUnsigned_ID;
    wire [1:0]wb_type_ID;
    wire ALUen_ID;
    wire ALUSrc1_ID;
    wire ALUSrc2_ID;
    wire [3:0]ALUOp_ID;
    wire Branch_ID;
    wire [2:0]Branch_type_ID;
    wire Jump_ID;
    wire [31:0]immediate_ID;
    wire valid_out_ID;

    // stage3-EX
    wire [3:0]opcode_EX;
    wire [31:0]oprand1_EX;
    wire [31:0]oprand2_EX;
    wire en_EX;
    wire flush_EX;
    wire valid_in_EX;
    wire stall_EX;
    wire [31:0]out_EX;
    wire valid_out_EX;

    // stage4-MEM
    wire [1:0]MemSize_MEM;
    wire MemUnsigned_MEM;
    wire wr_en_MEM;
    wire [15:0]wr_addr_MEM;
    wire [31:0]wr_data_MEM;
    wire rd_en_MEM;
    wire [15:0]rd_addr_MEM;
    wire [31:0]rd_data_MEM;

    // stage5-WB
    wire wr_en_WB;
    wire [4:0]wr_addr_WB;
    wire [31:0]wr_data_WB;
    wire [4:0]rd_addr1_WB;
    wire [4:0]rd_addr2_WB;
    wire [31:0]rd_data1_WB;
    wire [31:0]rd_data2_WB;

    //----------------------------------------------


    //---------------------core----------------------
    // state1-IF
    PC u_PC(
        .clk        (clk        ),
        .rst_n      (rst_n      ),
        .load_pc_en (load_pc_en ),
        .load_pc    (load_pc    ),
        .stall      (stall_IF    ),
        .flush      (flush_IF    ),
        .valid_in   (valid_in_IF ),
        .valid_out  (valid_out_IF),
        .pc         (pc         )
    );

    ROM u_ROM(
        .pc          (pc          ),
        .instruction (instruction )
    );
    
    // state2-ID
    decoder u_decoder(
        .instruction (instruction ),
        .clk         (clk         ),
        .rst_n       (rst_n       ),
        .valid_in    (valid_in_ID    ),
        .flush       (flush_ID       ),
        .stall       (stall_ID       ),
        .rs1_addr    (rs1_addr_ID    ),
        .rs2_addr    (rs2_addr_ID    ),
        .rd_addr     (rd_addr_ID     ),
        .RegWrite    (RegWrite_ID    ),
        .MemRead     (MemRead_ID     ),
        .MemWrite    (MemWrite_ID    ),
        .MemSize     (MemSize_ID     ),
        .MemUnsigned (MemUnsigned_ID ),
        .wb_type     (wb_type_ID     ),
        .ALUen       (ALUen_ID       ),
        .ALUSrc1     (ALUSrc1_ID     ),
        .ALUSrc2     (ALUSrc2_ID     ),
        .ALUOp       (ALUOp_ID       ),
        .Branch      (Branch_ID      ),
        .Branch_type (Branch_type_ID ),
        .Jump        (Jump_ID        ),
        .immediate   (immediate_ID   ),
        .valid_out   (valid_out_ID   )
    );

    assign valid_in_ID = valid_out_IF;  // <---------------stage2还没开始连线
    

    // state3-EX
    ALU u_ALU(
        .clk       (clk       ),
        .opcode    (opcode_EX    ),
        .oprand1   (oprand1_EX   ),
        .oprand2   (oprand2_EX   ),
        .en        (en_EX        ),
        .flush     (flush_EX     ),
        .valid_in  (valid_in_EX  ),
        .stall     (stall_EX     ),
        .out       (out_EX       ),
        .valid_out (valid_out_EX )
    );
    

    // state4-MEM
    // 64KB内存,addr:0-65535 
    memory #(
        .DATA_WIDTH(8),
        .ADDR_WIDTH(16)
    ) u_memory(
        .clk         (clk         ),
        .rst_n       (rst_n       ),
        .MemSize     (MemSize_MEM     ),
        .MemUnsigned (MemUnsigned_MEM ),
        .wr_en       (wr_en_MEM       ),
        .wr_addr     (wr_addr_MEM     ),
        .wr_data     (wr_data_MEM     ),
        .rd_en       (rd_en_MEM       ),
        .rd_addr     (rd_addr_MEM     ),
        .rd_data     (rd_data_MEM     )
    );
    

    // state5-WB
    GPR_matrix u_GPR_matrix(
        .clk      (clk      ),
        .rst_n    (rst_n    ),
        .wr_en    (wr_en_WB    ),
        .wr_addr  (wr_addr_WB  ),
        .wr_data  (wr_data_WB  ),
        .rd_addr1 (rd_addr1_WB ),
        .rd_addr2 (rd_addr2_WB ),
        .rd_data1 (rd_data1_WB ),
        .rd_data2 (rd_data2_WB )
    );

    
    //----------------------------------------------
endmodule
