`timescale 1ns/1ps
`default_nettype none

// 用独立 Python 数学参考检查原始卷积结果；存储适配器按坐标读取向量，
// 不复制 RTL 的循环状态机。请求、响应和输出均插入停顿。
module TB_conv2d_core;
    parameter integer ACT_WIDTH = 8, WEIGHT_WIDTH = 8;
    reg clk = 0, rst_n = 0;
    always #20 clk = ~clk;
    reg cmd_valid = 0, cfg_bias_enable = 0, clear_status = 0;
    reg [15:0] cfg_in_h = 0, cfg_in_w = 0, cfg_in_ch = 0, cfg_out_ch = 0;
    reg [1:0] cfg_kernel = 1, cfg_stride = 1, cfg_padding = 0;
    wire cmd_ready, busy, done, error;
    wire [1:0] error_code;
    wire [16:0] out_h, out_w;
    wire req_valid, req_bias, rsp_ready, out_valid, out_last;
    reg req_ready = 0, rsp_valid = 0, out_ready = 0;
    wire [15:0] req_in_y, req_in_x, req_in_ch, req_out_ch, out_ch;
    wire [1:0] req_ky, req_kx;
    reg signed [ACT_WIDTH-1:0] rsp_input = 0;
    reg signed [WEIGHT_WIDTH-1:0] rsp_weight = 0;
    reg signed [31:0] rsp_bias = 0;
    wire signed [63:0] out_sum;
    wire [16:0] out_y, out_x;
    conv2d_core #(.ACT_WIDTH(ACT_WIDTH), .WEIGHT_WIDTH(WEIGHT_WIDTH)) dut (.*);

    reg [287:0] jobs [0:255];
    reg signed [ACT_WIDTH-1:0] image [0:131071];
    reg signed [WEIGHT_WIDTH-1:0] weight [0:131071];
    reg signed [31:0] bias [0:8191];
    reg signed [63:0] expected [0:131071];
    integer job_count, input_count, weight_count, bias_count, expected_count;
    integer job = 0, actual = 0, cycle = 0, response_delay = 0;
    integer height, width, ci, co, kernel, oh, ow, expected_outputs;
    integer image_base, weight_base, bias_base, expected_base;
    integer data_index, weight_index, checked = 0, negatives = 0, resets = 0;
    reg active = 0, pending = 0;
    reg pause_requests = 0, pause_responses = 0, pause_outputs = 0;
    reg signed [ACT_WIDTH-1:0] saved_input;
    reg signed [WEIGHT_WIDTH-1:0] saved_weight;
    reg signed [31:0] saved_bias;
    reg request_held = 0, output_held = 0;
    reg [68:0] request_snapshot;
    reg [114:0] output_snapshot;
    wire [68:0] request_payload = {req_bias, req_in_y, req_in_x, req_in_ch, req_out_ch, req_ky, req_kx};
    wire [114:0] output_payload = {out_sum, out_y, out_x, out_ch, out_last};

    // 存储响应只在请求握手后生成，并保持到核心消费；复位清除在途请求。
    always @(negedge clk) begin
        req_ready = rst_n && !pause_requests && !pending && cycle % 5 != 0;
        rsp_valid = rst_n && !pause_responses && pending && response_delay == 0;
        out_ready = rst_n && !pause_outputs && cycle % 7 != 0 && cycle % 7 != 1;
        rsp_input = saved_input; rsp_weight = saved_weight; rsp_bias = saved_bias;
    end
    always @(posedge clk) begin
        if (!rst_n) begin
            pending <= 0; cycle <= 0; response_delay <= 0;
            request_held <= 0; output_held <= 0;
        end else begin
            cycle <= cycle + 1;
            if (request_held && (!req_valid || request_payload !== request_snapshot))
                $fatal(1,"request changed while waiting");
            if (output_held && (!out_valid || output_payload !== output_snapshot))
                $fatal(1,"output changed while waiting");
            request_held <= req_valid && !req_ready;
            output_held <= out_valid && !out_ready;
            request_snapshot <= request_payload; output_snapshot <= output_payload;
            if (pending && response_delay > 0) response_delay <= response_delay - 1;
            if (req_valid && req_ready) begin
                if (!active || pending) $fatal(1,"unexpected/multiple outstanding request");
                if (req_out_ch >= co) $fatal(1,"output channel out of bounds");
                pending <= 1; response_delay <= cycle % 4;
                saved_input <= 0; saved_weight <= 0;
                saved_bias <= bias[bias_base + req_out_ch];
                if (!req_bias) begin
                    if (req_in_y >= height || req_in_x >= width || req_in_ch >= ci ||
                        req_ky >= kernel || req_kx >= kernel)
                        $fatal(1,"input/weight request out of bounds");
                    data_index = (req_in_y*width + req_in_x)*ci + req_in_ch;
                    weight_index = ((req_out_ch*kernel + req_ky)*kernel + req_kx)*ci + req_in_ch;
                    saved_input <= image[image_base + data_index];
                    saved_weight <= weight[weight_base + weight_index];
                end else if (!jobs[job][70]) $fatal(1,"unexpected bias read");
            end
            if (rsp_valid && rsp_ready) pending <= 0;
            if (out_valid && out_ready) begin
                if (!active || actual >= expected_outputs) $fatal(1,"unexpected output");
                if (out_sum !== expected[expected_base+actual] ||
                    out_y !== actual/(ow*co) || out_x !== (actual/co)%ow || out_ch !== actual%co ||
                    out_last !== (actual == expected_outputs-1))
                    $fatal(1,"conv mismatch job=%0d output=%0d sum=%0d expected=%0d y/x/c=%0d/%0d/%0d",
                           job,actual,out_sum,expected[expected_base+actual],out_y,out_x,out_ch);
                actual = actual + 1; checked = checked + 1;
            end
            if (done && (busy || error)) $fatal(1,"done/status conflict");
            if (cmd_ready && busy) $fatal(1,"ready while busy");
        end
    end

    task launch;
        input integer index;
        begin
            @(negedge clk);
            job = index; actual = 0; active = 1;
            height = jobs[job][15:0]; width = jobs[job][31:16];
            ci = jobs[job][47:32]; co = jobs[job][63:48]; kernel = jobs[job][65:64];
            oh = (height + 2*jobs[job][69:68] - kernel)/jobs[job][67:66] + 1;
            ow = (width + 2*jobs[job][69:68] - kernel)/jobs[job][67:66] + 1;
            image_base = jobs[job][159:128]; weight_base = jobs[job][191:160];
            bias_base = jobs[job][223:192]; expected_base = jobs[job][255:224];
            expected_outputs = jobs[job][287:256];
            cfg_in_h = height; cfg_in_w = width; cfg_in_ch = ci; cfg_out_ch = co;
            cfg_kernel = kernel; cfg_stride = jobs[job][67:66];
            cfg_padding = jobs[job][69:68]; cfg_bias_enable = jobs[job][70];
            cmd_valid = 1;
            do @(posedge clk); while (!cmd_ready);
            @(negedge clk); cmd_valid = 0;
            if (error || done || !busy || out_h != oh || out_w != ow)
                $fatal(1,"command/shape mismatch");
            // 执行期间改动输入配置，检查核心使用命令快照。
            cfg_in_h = 0; cfg_in_w = 0; cfg_in_ch = 0; cfg_out_ch = 0;
            cfg_kernel = 0; cfg_stride = 0; cfg_padding = 3; cfg_bias_enable = !cfg_bias_enable;
        end
    endtask
    task finish_case;
        integer guard;
        begin
            guard = 0;
            while (busy) begin
                @(negedge clk); guard = guard + 1;
                if (guard > 1000000) $fatal(1,"conv timeout");
            end
            if (!done || error || actual != expected_outputs || pending)
                $fatal(1,"incomplete outputs/status");
            repeat(3) @(negedge clk);
            if (!done) $fatal(1,"done not sticky");
            active = 0;
        end
    endtask
    task invalid;
        input [15:0] h, w, ic, oc;
        input [1:0] k, s, p, code;
        begin
            @(negedge clk);
            cfg_in_h = h; cfg_in_w = w; cfg_in_ch = ic; cfg_out_ch = oc;
            cfg_kernel = k; cfg_stride = s; cfg_padding = p; cmd_valid = 1;
            @(negedge clk); cmd_valid = 0;
            if (busy || done || !error || error_code !== code || req_valid)
                $fatal(1,"invalid command accepted");
            clear_status = 1; @(negedge clk); clear_status = 0;
            if (error || done || error_code != 0) $fatal(1,"clear status failed");
            negatives = negatives + 1;
        end
    endtask
    task reset_all;
        begin
            @(negedge clk); rst_n = 0; cmd_valid = 0; clear_status = 0;
            repeat(4) @(negedge clk);
            pause_requests = 0; pause_responses = 0; pause_outputs = 0;
            rst_n = 1; active = 0;
            repeat(3) @(negedge clk);
            if (!cmd_ready || busy || done || error) $fatal(1,"reset status mismatch");
            resets = resets + 1;
        end
    endtask
    integer i;
    initial begin
        if (!$value$plusargs("JOBS=%d",job_count) || !$value$plusargs("INPUTS=%d",input_count) ||
            !$value$plusargs("WEIGHTS=%d",weight_count) || !$value$plusargs("BIASES=%d",bias_count) ||
            !$value$plusargs("OUTPUTS=%d",expected_count)) $fatal(1,"missing sizes");
        if (job_count > 256 || input_count > 131072 || weight_count > 131072 ||
            bias_count > 8192 || expected_count > 131072) $fatal(1,"fixture storage too small");
        $readmemh("jobs.mem",jobs,0,job_count-1); $readmemh("image.mem",image,0,input_count-1);
        $readmemh("weight.mem",weight,0,weight_count-1); $readmemh("bias.mem",bias,0,bias_count-1);
        $readmemh("expected.mem",expected,0,expected_count-1);
        reset_all;
        for (i = 0; i < job_count; i = i + 1) begin
            launch(i);
            repeat(3) @(negedge clk);
            // 忙时的新命令及清状态不能改变当前计算。
            if (busy) begin cmd_valid = 1; clear_status = 1; end
            @(negedge clk); cmd_valid = 0; clear_status = 0;
            finish_case;
        end
        invalid(0,3,1,1,1,1,0,1); invalid(3,0,1,1,1,1,0,1);
        invalid(3,3,0,1,1,1,0,1); invalid(3,3,1,0,1,1,0,1);
        invalid(3,3,1,1,0,1,0,2); invalid(3,3,1,1,2,1,0,2);
        invalid(3,3,1,1,1,0,0,2); invalid(3,3,1,1,1,3,0,2);
        invalid(3,3,1,1,1,1,2,2); invalid(3,3,1,1,1,1,3,2);
        invalid(1,3,1,1,3,1,0,3); invalid(3,1,1,1,3,1,0,3);
        // 最大尺寸的 +padding 输出要有 17 位，不能在 65535 处回绕。
        @(negedge clk); pause_requests = 1;
        cfg_in_h = 65535; cfg_in_w = 65535; cfg_in_ch = 1; cfg_out_ch = 1;
        cfg_kernel = 1; cfg_stride = 1; cfg_padding = 1; cfg_bias_enable = 1; cmd_valid = 1;
        @(negedge clk); cmd_valid = 0;
        if (out_h !== 17'd65537 || out_w !== 17'd65537) $fatal(1,"shape overflow");
        reset_all;
        // 分别在请求等待、响应等待、结果反压期间中断，然后复位后重新执行。
        pause_requests = 1; launch(0); wait(req_valid); reset_all;
        launch(0); finish_case;
        pause_responses = 1; launch(0); wait(pending); reset_all;
        launch(0); finish_case;
        pause_outputs = 1; launch(0); wait(out_valid);
        repeat(70) @(negedge clk); reset_all;
        launch(0); finish_case;
        $display("PASS conv2d W%0dA%0d layers=%0d outputs=%0d invalid=%0d resets=%0d",
                 WEIGHT_WIDTH,ACT_WIDTH,job_count,checked,negatives,resets);
        $finish;
    end
    initial begin
        #2000000000;
        $fatal(1,"global timeout");
    end
endmodule
`default_nettype wire
