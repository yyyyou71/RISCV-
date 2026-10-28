module acore_fetch_queue (
    input clk, rst_n, redirect,
    input [31:0] redirect_pc,
    input prediction,
    input [31:0] prediction_pc,
    output reg [31:0] request_pc,
    input [1:0] consume,
    output valid, second_valid,
    output [31:0] head_pc, head_instruction, second_instruction,
    output head_prediction,
    output [31:0] head_prediction_pc
);
    reg [31:0] instructions [0:7];
    reg [31:0] pcs [0:7];
    reg predictions [0:7];
    reg [31:0] targets [0:7];
    reg [2:0] read_ptr, write_ptr;
    reg [3:0] count;
    reg pending;
    reg [1:0] pending_words;
    reg [31:0] pending_pc, pending_target;
    reg pending_prediction;
    wire [2:0] read_next = read_ptr + 3'd1;
    wire [2:0] write_next = write_ptr + 3'd1;
    wire [3:0] reserved = count + (pending ? {2'b0, pending_words} : 4'd0) - {2'b0, consume};
    wire request = rst_n && !redirect && reserved <= 4'd6;
    wire [31:0] word0, word1;
    wire [31:0] next_word_pc = request_pc + 32'd4;
    acore_fetch_memory u_memory (
        .clk(clk), .rst(!rst_n), .enable(request),
        .addr_a(request_pc[14:2]), .addr_b(next_word_pc[14:2]),
        .data_a(word0), .data_b(word1)
    );
    assign valid = count != 0;
    assign second_valid = count >= 2 && pcs[read_next] == pcs[read_ptr] + 32'd4;
    assign head_pc = valid ? pcs[read_ptr] : 32'b0;
    assign head_instruction = valid ? instructions[read_ptr] : 32'h00000013;
    assign second_instruction = second_valid ? instructions[read_next] : 32'h00000013;
    assign head_prediction = valid && predictions[read_ptr];
    assign head_prediction_pc = valid ? targets[read_ptr] : 32'b0;
    always @(posedge clk) begin
        if (!rst_n || redirect) begin
            request_pc <= !rst_n ? 32'b0 : redirect_pc;
            read_ptr <= 0;
            write_ptr <= 0;
            count <= 0;
            pending <= 0;
            pending_words <= 0;
            pending_pc <= 0;
            pending_target <= 0;
            pending_prediction <= 0;
        end else begin
            pending <= request;
            if (request) begin
                pending_words <= prediction ? 2'd1 : 2'd2;
                pending_pc <= request_pc;
                pending_target <= prediction_pc;
                pending_prediction <= prediction;
                request_pc <= prediction ? prediction_pc : request_pc + 32'd8;
            end
            count <= reserved;
            read_ptr <= read_ptr + {1'b0, consume};
            if (pending) begin
                instructions[write_ptr] <= pending_pc[31:15] == 0 ? word0 : 32'h00000013;
                pcs[write_ptr] <= pending_pc;
                predictions[write_ptr] <= pending_prediction;
                targets[write_ptr] <= pending_target;
                if (pending_words == 2) begin
                    instructions[write_next] <= pending_pc < 32'h7ffc ? word1 : 32'h00000013;
                    pcs[write_next] <= pending_pc + 32'd4;
                    predictions[write_next] <= 0;
                    targets[write_next] <= 0;
                end
                write_ptr <= write_ptr + {1'b0, pending_words};
            end
        end
    end
    // synthesis translate_off
    always @(posedge clk) if (rst_n && !redirect) begin
        if (count > 8 || reserved > 8 || {2'b0, consume} > count)
            $fatal(1, "Fetch queue overflow or underflow");
        if (consume == 2 && !second_valid)
            $fatal(1, "Noncontiguous dual issue");
    end
    // synthesis translate_on
endmodule
