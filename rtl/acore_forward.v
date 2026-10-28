module acore_forward (
    input a_ex_we, a_ex_ready, b_ex_we, a_wb_we, b_wb_we,
    input [4:0] a_ex_rd, b_ex_rd, a_wb_rd, b_wb_rd,
    input [31:0] a_ex_data, b_ex_data, a_wb_data, b_wb_data,
    input [4:0] rs1, rs2, rs3, rs4,
    output hit1, hit2, hit3, hit4,
    output [31:0] data1, data2, data3, data4,
    output stall
);
    function [33:0] resolve;
        input [4:0] rs;
        input [38:0] ex_a;
        input [37:0] ex_b, wb_a, wb_b;
        begin
            if (rs == 0) resolve = 34'b0;
            else if (ex_b[37] && ex_b[36:32] == rs) resolve = {1'b0, 1'b1, ex_b[31:0]};
            else if (ex_a[38] && ex_a[36:32] == rs) resolve = {!ex_a[37], 1'b1, ex_a[31:0]};
            else if (wb_b[37] && wb_b[36:32] == rs) resolve = {1'b0, 1'b1, wb_b[31:0]};
            else if (wb_a[37] && wb_a[36:32] == rs) resolve = {1'b0, 1'b1, wb_a[31:0]};
            else resolve = 34'b0;
        end
    endfunction
    wire [38:0] ex_a = {a_ex_we, a_ex_ready, a_ex_rd, a_ex_data};
    wire [37:0] ex_b = {b_ex_we, b_ex_rd, b_ex_data};
    wire [37:0] wb_a = {a_wb_we, a_wb_rd, a_wb_data};
    wire [37:0] wb_b = {b_wb_we, b_wb_rd, b_wb_data};
    wire [33:0] r1 = resolve(rs1, ex_a, ex_b, wb_a, wb_b);
    wire [33:0] r2 = resolve(rs2, ex_a, ex_b, wb_a, wb_b);
    wire [33:0] r3 = resolve(rs3, ex_a, ex_b, wb_a, wb_b);
    wire [33:0] r4 = resolve(rs4, ex_a, ex_b, wb_a, wb_b);
    assign {hit1, data1} = r1[32:0];
    assign {hit2, data2} = r2[32:0];
    assign {hit3, data3} = r3[32:0];
    assign {hit4, data4} = r4[32:0];
    assign stall = r1[33] || r2[33] || r3[33] || r4[33];
endmodule
