`timescale 1ns/1ps
module TB_conv2d_w8a16_core;
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    reg start_valid=0,load_valid=0,load_weight=0,block_valid=0,out_ready=0;
    reg [3:0] cfg_taps=1,cfg_lane_mask=0,load_tap=0;
    reg [15:0] cfg_blocks0=0,cfg_blocks1=0;
    reg [127:0] cfg_mult_m0=0,cfg_mult_m1=0,cfg_bias_q13=0,cfg_mult_y=0;
    reg [31:0] cfg_shift_m0=0,cfg_shift_m1=0,cfg_shift_y=0;
    reg cfg_relu=0,compute_enable=0,force_pause=0;
    reg [1:0] load_lane=0;
    reg [255:0] load_data=0;
    wire start_ready,load_ready,block_ready,busy,issue_valid,out_valid,out_error;
    wire [63:0] out_data;
    wire [3:0] out_clamped;
    conv2d_w8a16_core dut(.*);
    reg [831:0] jobs[0:511];
    reg [255:0] inputs[0:131071];
    reg [127:0] weights[0:524287];
    integer cases,words,index,b,t,l,base,total_blocks,taps,cycle=0,issues=0,checked=0,kind;
    reg held=0;
    reg [68:0] held_result;
    always @(negedge clk) compute_enable=!force_pause && cycle%11>2;
    always @(posedge clk) begin
        if(!rst_n)begin cycle<=0;held<=0;end
        else begin
            cycle<=cycle+1;
            if(issue_valid)begin
                if(!compute_enable)$fatal(1,"issue while paused");
                issues=issues+1;
            end
            if(held && (!out_valid || {out_error,out_clamped,out_data}!==held_result))
                $fatal(1,"core changed under backpressure");
            held<=out_valid && !out_ready;held_result<={out_error,out_clamped,out_data};
        end
    end
    task launch;
        input integer n;
        begin
            @(negedge clk);
            cfg_taps=jobs[n][3:0];cfg_blocks0=jobs[n][47:32];cfg_blocks1=jobs[n][63:48];
            cfg_lane_mask=jobs[n][67:64];cfg_relu=jobs[n][68];
            cfg_shift_m0=jobs[n][127:96];cfg_shift_m1=jobs[n][159:128];cfg_shift_y=jobs[n][191:160];
            cfg_mult_m0=jobs[n][319:192];cfg_mult_m1=jobs[n][447:320];
            cfg_bias_q13=jobs[n][575:448];cfg_mult_y=jobs[n][703:576];
            if(!start_ready)$fatal(1,"core start not ready");
            start_valid=1;issues=0;
            @(negedge clk);start_valid=0;
            cfg_taps=0;cfg_blocks0=0;cfg_blocks1=0;cfg_lane_mask=0;cfg_relu=0;
            cfg_mult_m0=0;cfg_mult_m1=0;cfg_bias_q13=0;cfg_mult_y=0;
            cfg_shift_m0=0;cfg_shift_m1=0;cfg_shift_y=0;
            // 缓存没装满时，block_valid 不能启动；以前一次结果不能充当新输入。
            block_valid=1;
            repeat(2)begin @(negedge clk);if(block_ready || issue_valid)$fatal(1,"stale cache accepted");end
            block_valid=0;
        end
    endtask
    task send_block;
        input integer word_base,ntaps;
        begin
            for(t=0;t<ntaps;t=t+1)begin
                @(negedge clk);load_valid=1;load_weight=0;load_tap=t;load_data=inputs[word_base+t];
                if(!load_ready)$fatal(1,"input load stalled");
                @(negedge clk);load_valid=0;
                for(l=0;l<4;l=l+1)begin
                    @(negedge clk);load_valid=1;load_weight=1;load_lane=l;
                    load_data={128'd0,weights[(word_base+t)*4+l]};
                    if(!load_ready)$fatal(1,"weight load stalled");
                    @(negedge clk);load_valid=0;
                end
            end
            if(!block_ready)$fatal(1,"complete block not ready");
            block_valid=1;@(negedge clk);block_valid=0;
        end
    endtask
    task finish;
        input integer n;
        begin
            wait(out_valid);@(negedge clk);
            if(out_error || out_data!==jobs[n][767:704] || out_clamped!==jobs[n][771:768] ||
                issues!=(jobs[n][47:32]+jobs[n][63:48])*jobs[n][3:0]*8)
                $fatal(1,"core mismatch case=%0d got=%h expected=%h err=%b clamp=%h/%h issues=%0d",n,
                    out_data,jobs[n][767:704],out_error,out_clamped,jobs[n][771:768],issues);
            repeat(5)@(negedge clk);
            out_ready=1;@(negedge clk);out_ready=0;
            if(busy || !start_ready)$fatal(1,"core failed to retire");
            checked=checked+1;
        end
    endtask
    task run_case;
        input integer n;
        begin
            launch(n);base=jobs[n][831:800];taps=jobs[n][3:0];total_blocks=jobs[n][47:32]+jobs[n][63:48];
            for(b=0;b<total_blocks;b=b+1)begin
                if(b!=0)wait(block_ready || load_ready);
                send_block(base+b*taps,taps);
                if(n==1 && b==0)begin
                    wait(issues>=3);@(negedge clk);force_pause=1;
                    repeat(30)@(negedge clk);force_pause=0;
                end
            end
            finish(n);
        end
    endtask
    initial begin
        if(!$value$plusargs("CASES=%d",cases) || !$value$plusargs("WORDS=%d",words) ||
            cases>512 || words>131072)$fatal(1,"invalid vector counts");
        $readmemh("jobs.mem",jobs,0,cases-1);$readmemh("inputs.mem",inputs,0,words-1);
        $readmemh("weights.mem",weights,0,words*4-1);
        repeat(3)@(negedge clk);rst_n=1;
        for(index=0;index<cases;index=index+1)run_case(index);
        // 非法命令返回可握手错误，消费后可重新提交。
        for(kind=0;kind<3;kind=kind+1)begin
            @(negedge clk);cfg_taps=kind==0 ? 2:1;cfg_blocks0=kind==1 ? 0:1;
            cfg_lane_mask=kind==2 ? 0:15;start_valid=1;
            @(negedge clk);start_valid=0;
            if(!out_valid || !out_error || out_data!=0)$fatal(1,"invalid command accepted");
            out_ready=1;@(negedge clk);out_ready=0;
        end
        // MAC 流水中复位，再次执行同一任务，旧 valid 和部分和必须清空。
        launch(0);send_block(jobs[0][831:800],jobs[0][3:0]);wait(issues>=3);
        @(negedge clk);rst_n=0;repeat(3)@(negedge clk);rst_n=1;
        repeat(5)begin @(negedge clk);if(out_valid || busy || issue_valid)$fatal(1,"stale result after reset");end
        run_case(0);
        // 结果反压时复位，随后检查缓存不能跨复位沿用。
        launch(0);send_block(jobs[0][831:800],jobs[0][3:0]);wait(out_valid);
        @(negedge clk);rst_n=0;repeat(3)@(negedge clk);rst_n=1;run_case(0);
        $display("PASS conv2d_w8a16 cases=%0d outputs=%0d invalid=3 reset_replays=2",checked,checked*4);$finish;
    end
    initial begin #100000000;$fatal(1,"W8A16 core timeout");end
endmodule
