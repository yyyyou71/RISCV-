`timescale 1ns/1ps
`default_nettype none
// W8A8 的 4 输出通道 x 2 项归约通路。128 位缓存字含 8 对操作数。
// 输入广播，权重分为四个独立银行；同步读缓存后连续送入真实 IP 边界。
// 不传递模型专用参数覆盖：可用默认配置的厂商 multiply_adder 替换。
module conv_mac_tile (
    input wire clk, rst_n,
    input wire load_valid,
    output wire load_ready,
    input wire load_weight,
    input wire [1:0] load_lane,
    input wire [3:0] load_tap,
    input wire [127:0] load_data,
    input wire start_valid,
    output wire start_ready,
    input wire [3:0] tap_count, // 1 或 9；每个 tap 固定包含 16 个输入通道
    input wire [255:0] initial_sums,
    input wire compute_enable,
    output wire busy,
    output reg error,
    output wire out_valid,
    input wire out_ready,
    output wire [255:0] out_sums,
    output wire issue_valid
);
    localparam [1:0] IDLE=0, RUN=1, OUTPUT=2;
    reg [1:0] state;
    reg [3:0] taps, issue_tap;
    reg [2:0] issue_slot, read_slot;
    reg issuing, read_valid, read_last;
    reg [2:0] valid_pipe, last_pipe;
    reg [8:0] input_valid;
    wire [8:0] weight_valid [0:3];
    reg [127:0] input_mem [0:8];
    reg [127:0] input_word;
    reg signed [63:0] sums [0:3];
    wire [16:0] pair_sum [0:3];
    wire [8:0] required_mask = tap_count == 1 ? 9'b1 : 9'h1ff;
    wire cache_ready = (input_valid & required_mask) == required_mask &&
        (weight_valid[0] & required_mask) == required_mask &&
        (weight_valid[1] & required_mask) == required_mask &&
        (weight_valid[2] & required_mask) == required_mask &&
        (weight_valid[3] & required_mask) == required_mask;
    wire start_fire = start_valid && start_ready;
    wire advance = state == RUN && compute_enable;
    wire ip_reset = !rst_n || start_fire;
    wire [15:0] input_pair = input_word[read_slot*16 +: 16];
    assign start_ready = rst_n && state == IDLE;
    assign load_ready = rst_n && state == IDLE && !start_valid && load_tap < 9;
    assign busy = state != IDLE;
    assign out_valid = rst_n && state == OUTPUT;
    assign issue_valid = advance && issuing;
    genvar lane;
    generate for (lane=0; lane<4; lane=lane+1) begin : g_lane
        reg [127:0] bank [0:8];
        reg [127:0] word_reg;
        reg [8:0] valid_words;
        wire [15:0] weight_pair = word_reg[read_slot*16 +: 16];
        assign weight_valid[lane] = valid_words;
        assign out_sums[lane*64 +: 64] = sums[lane];
        always @(posedge clk) begin
            if (load_valid && load_ready && load_weight && load_lane == lane)
                bank[load_tap] <= load_data;
            if (issue_valid) word_reg <= bank[issue_tap];
        end
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) valid_words <= 0;
            else if (load_valid && load_ready && load_weight && load_lane == lane)
                valid_words[load_tap] <= 1;
        end
        multiply_adder u_ip (
            .a0(input_pair[7:0]), .a1(input_pair[15:8]),
            .b0(weight_pair[7:0]), .b1(weight_pair[15:8]),
            .clk(clk), .rst(ip_reset), .ce(advance), .addsub(1'b0), .p(pair_sum[lane])
        );
    end endgenerate
    always @(posedge clk) begin
        if (load_valid && load_ready && !load_weight) input_mem[load_tap] <= load_data;
        if (issue_valid) input_word <= input_mem[issue_tap];
    end
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=IDLE; error<=0; input_valid<=0; taps<=1;
            issue_tap<=0; issue_slot<=0; read_slot<=0; issuing<=0;
            read_valid<=0; read_last<=0; valid_pipe<=0; last_pipe<=0;
            for (i=0;i<4;i=i+1) sums[i]<=0;
        end else begin
            if (load_valid && load_ready && !load_weight) input_valid[load_tap]<=1;
            if (start_fire) begin
                error<=0;
                if ((tap_count!=1 && tap_count!=9) || !cache_ready) error<=1;
                else begin
                    state<=RUN; taps<=tap_count; issue_tap<=0; issue_slot<=0; issuing<=1;
                    read_valid<=0; read_last<=0; valid_pipe<=0; last_pipe<=0;
                    for (i=0;i<4;i=i+1) sums[i]<=initial_sums[i*64 +: 64];
                end
            end
            if (advance) begin
                read_valid<=issuing;
                read_last<=issuing && issue_tap==taps-1'b1 && issue_slot==7;
                if (issuing) begin
                    read_slot<=issue_slot;
                    if (issue_slot==7) begin
                        issue_slot<=0;
                        if (issue_tap==taps-1'b1) issuing<=0;
                        else issue_tap<=issue_tap+1'b1;
                    end else issue_slot<=issue_slot+1'b1;
                end
                // 与同步缓存读、IP 的三个使能时钟严格配平；空泡仍推进流水。
                valid_pipe<={valid_pipe[1:0],read_valid};
                last_pipe<={last_pipe[1:0],read_last};
                if (valid_pipe[2]) begin
                    for (i=0;i<4;i=i+1)
                        sums[i]<=sums[i]+{{47{pair_sum[i][16]}},pair_sum[i]};
                    if (last_pipe[2]) state<=OUTPUT;
                end
            end
            if (out_valid && out_ready) state<=IDLE;
        end
    end
endmodule
`default_nettype wire
