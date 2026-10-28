`timescale 1ns/1ps
module TB_evolve5_ip;
    GTP_GRS GRS_INST (.GRS_N(1'b1));
    reg clk = 0;
    reg rst = 1;
    reg [12:0] address = 0;
    reg write_enable = 0;
    reg [3:0] byte_enable = 0;
    reg [31:0] write_data = 0;
    wire [31:0] rom_data, ram_data;
    reg [31:0] rom_image [0:8191];
    reg [31:0] ram_image [0:8191];
    reg [31:0] reference_word;
    integer word_index, mask_index, byte_index;
    reg req_valid = 0;
    wire req_ready, rsp_valid;
    reg rsp_ready = 0;
    reg kill = 0;
    reg [2:0] operation = 0;
    reg [31:0] operand_a = 0, operand_b = 0;
    wire [31:0] result;
    reg signed [63:0] signed_a, signed_b;
    reg [63:0] reference_product;
    reg [31:0] expected_result;
    reg [31:0] edges [0:5];
    integer operation_index, left_index, right_index;
    reg [31:0] instruction = 0;
    wire illegal;
    always #20 clk = ~clk;

    pango_evolve_rom rom (.clk(clk), .rst(rst), .addr_strobe(1'b0), .addr(address), .rd_data(rom_data));
    pango_evolve_ram ram (
        .a_clk(clk), .a_rst(rst), .a_addr(address), .a_wr_en(write_enable),
        .a_wr_byte_en(byte_enable), .a_wr_data(write_data), .a_rd_data(ram_data),
        .b_clk(clk), .b_rst(rst), .b_addr(13'b0), .b_wr_en(1'b0), .b_wr_byte_en(4'b0), .b_wr_data(32'b0), .b_rd_data()
    );
    rv32_muldiv #(.FAST_MUL(1), .DIV_ENABLE(0)) unit_under_test (
        .clk(clk), .rst(rst), .kill(kill), .req_valid(req_valid), .req_ready(req_ready),
        .req_op(operation), .req_a(operand_a), .req_b(operand_b),
        .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .result(result)
    );
    rv32_decode #(.M_ENABLE(1), .DIV_ENABLE(0)) decoder (
        .insn(instruction), .illegal(illegal), .rs1(), .rs2(), .rd(), .use_rs1(), .use_rs2(), .rd_write(),
        .imm(), .alu_op(), .a_is_pc(), .b_is_imm(), .is_load(), .is_store(), .is_branch(), .is_jal(), .is_jalr(),
        .funct3(), .ecall(), .ebreak()
    );

    task multiply;
        input [2:0] kind;
        input [31:0] value_a, value_b;
        begin
            @(negedge clk);
            operation = kind;
            operand_a = value_a;
            operand_b = value_b;
            signed_a = {{32{value_a[31]}}, value_a};
            signed_b = {{32{value_b[31]}}, value_b};
            case (kind)
                0,3: reference_product = {32'b0,value_a} * {32'b0,value_b};
                1: reference_product = signed_a * signed_b;
                2: reference_product = signed_a * $signed({32'b0,value_b});
            endcase
            expected_result = kind == 0 ? reference_product[31:0] : reference_product[63:32];
            if (!req_ready) $fatal(1, "Multiplier not ready");
            req_valid = 1;
            @(negedge clk);
            req_valid = 0;
            wait (rsp_valid);
            repeat (3) begin
                @(negedge clk);
                if (!rsp_valid || result !== expected_result) $fatal(1, "Multiplier result/backpressure mismatch");
            end
            rsp_ready = 1;
            @(negedge clk);
            rsp_ready = 0;
        end
    endtask

    initial begin
        $readmemh("firmware/evolve5_rom.hex", rom_image);
        $readmemh("firmware/evolve5_ram.hex", ram_image);
        repeat (3) @(negedge clk);
        rst = 0;
        for (word_index = 0; word_index < 8192; word_index = word_index + 1) begin
            @(negedge clk);
            address = word_index[12:0];
            @(posedge clk);
            #1;
            if (rom_data !== rom_image[word_index] || ram_data !== ram_image[word_index])
                $fatal(1, "EVOLVE5 IP image mismatch at %0d", word_index);
        end
        for (mask_index = 0; mask_index < 16; mask_index = mask_index + 1) begin
            @(negedge clk);
            address = 13'h1fff;
            write_enable = 1;
            byte_enable = 15;
            write_data = 32'h10203040;
            @(negedge clk);
            byte_enable = mask_index[3:0];
            write_data = 32'haabbccdd;
            reference_word = 32'h10203040;
            for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                if (mask_index[byte_index]) reference_word[byte_index*8 +: 8] = write_data[byte_index*8 +: 8];
            @(posedge clk);
            #1;
            if (ram_data !== reference_word) $fatal(1, "Transparent write or byte mask mismatch");
            @(negedge clk);
            write_enable = 0;
            @(posedge clk);
            #1;
            if (ram_data !== reference_word) $fatal(1, "Stored masked value mismatch");
        end
        edges[0]=0; edges[1]=1; edges[2]=32'hffffffff;
        edges[3]=32'h80000000; edges[4]=32'h7fffffff; edges[5]=32'h12345678;
        for (operation_index=0; operation_index<4; operation_index=operation_index+1)
            for (left_index=0; left_index<6; left_index=left_index+1)
                for (right_index=0; right_index<6; right_index=right_index+1)
                    multiply(operation_index[2:0], edges[left_index], edges[right_index]);
        @(negedge clk);
        req_valid = 1;
        @(negedge clk);
        req_valid = 0;
        kill = 1;
        @(negedge clk);
        kill = 0;
        #1;
        if (rsp_valid || !req_ready) $fatal(1, "Killed multiplier retained a response");
        for (operation_index=0; operation_index<8; operation_index=operation_index+1) begin
            instruction = {7'd1,5'd2,5'd1,operation_index[2:0],5'd3,7'h33};
            #1;
            if (illegal !== (operation_index >= 4)) $fatal(1, "Zmmul/DIV legality mismatch");
        end
        $display("PASS: EVOLVE5 ROM/RAM images, 16 byte masks, 144 multiply edge cases, kill and DIV disabled");
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1, "EVOLVE5 IP test timeout");
    end
endmodule
