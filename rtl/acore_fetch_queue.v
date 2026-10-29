module acore_fetch_queue (
    input clk, rst_n, redirect,
    input [31:0] redirect_pc,
    input prediction, second_prediction,
    input [31:0] prediction_pc, second_prediction_pc,
    output reg [31:0] request_pc,
    input [1:0] consume,
    output valid, second_valid,
    output [31:0] head_pc, head_instruction, second_instruction,
    output head_prediction,
    output [31:0] head_prediction_pc,
    output candidate_prediction,
    output [31:0] candidate_prediction_pc
);
    reg [31:0] instructions [0:7];
    reg [31:0] pcs [0:7];
    reg predictions [0:7];
    reg [31:0] targets [0:7];
    reg [2:0] read_ptr, write_ptr;
    reg [3:0] count;
    reg pending;
    reg [1:0] pending_words;
    reg [31:0] pending_pc, pending_target, pending_second_target;
    reg pending_prediction, pending_second_prediction;
    wire [2:0] read_next = read_ptr + 3'd1;
    wire [2:0] write_next = write_ptr + 3'd1;
    wire [3:0] available = count + (pending ? {2'b0, pending_words} : 4'd0);
    wire [3:0] remaining = available - {2'b0, consume};
    wire request = rst_n && (redirect || remaining <= 4'd6);
    wire [31:0] memory_pc = redirect ? redirect_pc : request_pc;
    wire [31:0] next_word_pc = memory_pc + 32'd4;
    wire [31:0] raw0, raw1;
    wire [31:0] word0 = pending_pc[31:15] == 0 ? raw0 : 32'h00000013;
    wire [31:0] word1 = pending_pc < 32'h7ffc ? raw1 : 32'h00000013;
    wire [1:0] pop_queue = count >= {2'b0, consume} ? consume : count[1:0];
    wire [1:0] pop_pending = consume - pop_queue;
    wire [1:0] push_words = pending ? pending_words - pop_pending : 2'd0;
    wire [31:0] second_pc = count >= 2 ? pcs[read_next] :
                            count == 1 ? pending_pc : pending_pc + 32'd4;
    acore_fetch_memory u_memory (
        .clk(clk), .rst(!rst_n), .enable(request),
        .addr_a(memory_pc[14:2]), .addr_b(next_word_pc[14:2]),
        .data_a(raw0), .data_b(raw1)
    );
    assign valid = available != 0;
    assign head_pc = count != 0 ? pcs[read_ptr] : pending_pc;
    assign head_instruction = count != 0 ? instructions[read_ptr] : valid ? word0 : 32'h00000013;
    assign head_prediction = valid && (count != 0 ? predictions[read_ptr] : pending_prediction);
    assign head_prediction_pc = count != 0 ? targets[read_ptr] : pending_target;
    assign second_valid = available >= 2 && second_pc == head_pc + 32'd4;
    assign second_instruction = !second_valid ? 32'h00000013 : count >= 2 ? instructions[read_next] :
                                count == 1 ? word0 : word1;
    assign candidate_prediction = second_valid && (count >= 2 ? predictions[read_next] :
                                  count == 1 ? pending_prediction : pending_second_prediction);
    assign candidate_prediction_pc = count >= 2 ? targets[read_next] :
                                      count == 1 ? pending_target : pending_second_target;
    always @(posedge clk) begin
        if (!rst_n) begin
            request_pc <= 0;
            read_ptr <= 0;
            write_ptr <= 0;
            count <= 0;
            pending <= 0;
            pending_words <= 0;
            pending_pc <= 0;
            pending_target <= 0;
            pending_second_target <= 0;
            pending_prediction <= 0;
            pending_second_prediction <= 0;
        end else if (redirect) begin
            request_pc <= redirect_pc + 32'd8;
            read_ptr <= 0;
            write_ptr <= 0;
            count <= 0;
            pending <= 1;
            pending_words <= 2;
            pending_pc <= redirect_pc;
            pending_target <= 0;
            pending_second_target <= 0;
            pending_prediction <= 0;
            pending_second_prediction <= 0;
        end else begin
            pending <= request;
            if (request) begin
                pending_words <= prediction ? 2'd1 : 2'd2;
                pending_pc <= request_pc;
                pending_target <= prediction_pc;
                pending_second_target <= second_prediction_pc;
                pending_prediction <= prediction;
                pending_second_prediction <= second_prediction;
                request_pc <= prediction ? prediction_pc : second_prediction ? second_prediction_pc : request_pc + 32'd8;
            end
            count <= remaining;
            read_ptr <= read_ptr + {1'b0, pop_queue};
            if (push_words != 0) begin
                instructions[write_ptr] <= pop_pending == 0 ? word0 : word1;
                pcs[write_ptr] <= pending_pc + (pop_pending == 0 ? 32'd0 : 32'd4);
                predictions[write_ptr] <= pop_pending == 0 ? pending_prediction : pending_second_prediction;
                targets[write_ptr] <= pop_pending == 0 ? pending_target : pending_second_target;
                if (push_words == 2) begin
                    instructions[write_next] <= word1;
                    pcs[write_next] <= pending_pc + 32'd4;
                    predictions[write_next] <= pending_second_prediction;
                    targets[write_next] <= pending_second_target;
                end
                write_ptr <= write_ptr + {1'b0, push_words};
            end
        end
    end
    // synthesis translate_off
    always @(posedge clk) if (rst_n && !redirect) begin
        if (count > 8 || remaining > 8 || {2'b0, consume} > available)
            $fatal(1, "Fetch queue overflow or underflow");
        if (consume == 2 && !second_valid)
            $fatal(1, "Noncontiguous dual issue");
    end
    // synthesis translate_on
endmodule
