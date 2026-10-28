`timescale 1ns/1ps
module TB_evolve5_memory;
    GTP_GRS GRS_INST (.GRS_N(1'b1));
    reg clk = 0;
    reg rst = 1;
    reg valid = 0, write_op = 0, instruction = 0, response_ready = 0;
    reg [31:0] address = 0, write_data = 0;
    reg [3:0] strobes = 0;
    reg [7:0] length = 0;
    wire command_ready, response_valid, response_error, response_last;
    wire [31:0] response_data;
    reg [31:0] rom_image [0:8191];
    reg [31:0] reference_data;
    reg reference_error;
    reg [31:0] current_address;
    integer beat_index;
    integer checked_beats = 0;
    always #20 clk = ~clk;
    rv32_soc_memory #(.BURST_INTERFACE(1)) dut (
        .clk(clk), .rst(rst), .iv(1'b0), .ia(32'b0), .ir(), .idata(), .ie(),
        .dv(1'b0), .dw(1'b0), .da(32'b0), .wd(32'b0), .ws(4'b0), .dr(), .rdata(), .de(),
        .b_cmd_valid(valid), .b_cmd_ready(command_ready), .b_cmd_write(write_op), .b_cmd_instr(instruction),
        .b_cmd_addr(address), .b_cmd_wdata(write_data), .b_cmd_wstrb(strobes), .b_cmd_len(length),
        .b_rsp_valid(response_valid), .b_rsp_ready(response_ready), .b_rsp_data(response_data),
        .b_rsp_error(response_error), .b_rsp_last(response_last)
    );

    task command;
        input write_value, instruction_value;
        input [31:0] address_value, data_value;
        input [3:0] strobe_value;
        input [7:0] length_value;
        begin
            @(negedge clk);
            if (!command_ready) $fatal(1, "Memory not ready");
            valid = 1;
            write_op = write_value;
            instruction = instruction_value;
            address = address_value;
            write_data = data_value;
            strobes = strobe_value;
            length = length_value;
            @(negedge clk);
            valid = 0;
        end
    endtask

    task finish_response;
        begin
            if (!response_valid) $fatal(1, "Missing memory response");
            repeat (3) begin
                @(negedge clk);
                if (!response_valid || response_data !== reference_data || response_error !== reference_error)
                    $fatal(1, "Memory response changed under backpressure");
            end
            response_ready = 1;
            @(negedge clk);
            response_ready = 0;
            checked_beats = checked_beats + 1;
        end
    endtask

    task read_rom;
        input [31:0] start_address;
        input [7:0] count_minus_one;
        begin
            command(0, 1, start_address, 0, 0, count_minus_one);
            for (beat_index = 0; beat_index <= count_minus_one; beat_index = beat_index + 1) begin
                current_address = start_address + 4*beat_index;
                reference_error = current_address >= 32768 || current_address[1:0] != 0;
                reference_data = reference_error ? 0 : rom_image[current_address >> 2];
                if (response_last !== (beat_index == count_minus_one)) $fatal(1, "Burst last mismatch");
                finish_response();
            end
        end
    endtask

    initial begin
        $readmemh("firmware/evolve5_rom.hex", rom_image);
        repeat (3) @(negedge clk);
        rst = 0;
        read_rom(0, 3);
        read_rom(32'h7ffc, 1);
        read_rom(32'h3, 0);
        command(0, 0, 32'h20007ffc, 0, 0, 0);
        reference_error = 0; reference_data = 0;
        finish_response();
        command(1, 0, 32'h20007ffc, 32'haabbccdd, 4'b0101, 0);
        reference_error = 0; reference_data = 0;
        if (dut.ram_data !== 0) $fatal(1, "Write took effect before response acceptance");
        finish_response();
        command(0, 0, 32'h20007ffc, 0, 0, 0);
        reference_error = 0; reference_data = 32'h00bb00dd;
        finish_response();
        command(1, 0, 0, 32'hffffffff, 15, 0);
        reference_error = 1; reference_data = 0;
        finish_response();
        command(0, 1, 32'h20000000, 0, 0, 0);
        reference_error = 1; reference_data = 0;
        finish_response();
        command(1, 0, 32'h20007ffc, 32'hbadf00d, 15, 0);
        rst = 1;
        #1;
        if (response_valid) $fatal(1, "Reset retained pending response");
        repeat (3) @(negedge clk);
        rst = 0;
        command(0, 0, 32'h20007ffc, 0, 0, 0);
        reference_error = 0; reference_data = 32'h00bb00dd;
        finish_response();
        $display("PASS: EVOLVE5 burst memory, %0d beats, backpressure, bounds, byte strobes and reset cancellation", checked_beats);
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "Burst memory test timeout");
    end
endmodule
