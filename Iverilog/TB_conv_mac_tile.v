`timescale 1ns/1ps
module TB_conv_mac_tile;
    reg clk=0,rst_n=0;
    always #10 clk=~clk;
    reg load_valid=0,load_weight=0,start_valid=0,out_ready=0;
    reg [1:0] load_lane=0;
    reg [3:0] load_tap=0,tap_count=1;
    reg [127:0] load_data=0;
    reg [255:0] initial_sums=0;
    reg compute_enable=0,force_pause=0;
    wire load_ready,start_ready,busy,error,out_valid,issue_valid;
    wire [255:0] out_sums;
    conv_mac_tile dut(.*);
    reg [127:0] inputs[0:255],weights[0:1023];
    reg [255:0] initials[0:31],golden[0:31];
    integer jobs,job=0,t,l,cycle=0,issues=0,checked=0,expected_pairs=0;
    reg held=0;
    reg [255:0] held_sum;
    always @(negedge clk) begin compute_enable=!force_pause && (job%5==0 || cycle%9>1);end
    always @(posedge clk) begin
        if(!rst_n)begin cycle<=0;issues=0;held<=0;end
        else begin
            cycle<=cycle+1;
            if(busy && !out_valid && compute_enable && issues<expected_pairs && !issue_valid)
                $fatal(1,"cache failed to supply a pair on an enabled cycle");
            if(issue_valid)issues=issues+1;
            if(held && (!out_valid || out_sums!==held_sum))$fatal(1,"output changed under backpressure");
            held<=out_valid && !out_ready;held_sum<=out_sums;
        end
    end
    task load;
        input integer index;
        input reload_weights;
        begin
            for(t=0;t<9;t=t+1)begin
                @(negedge clk);load_valid=1;load_weight=0;load_tap=t;load_data=inputs[index*9+t];
                if(!load_ready)$fatal(1,"load not ready");
                @(negedge clk);load_valid=0;
            end
            if(reload_weights)for(l=0;l<4;l=l+1)for(t=0;t<9;t=t+1)begin
                @(negedge clk);load_valid=1;load_weight=1;load_lane=l;load_tap=t;load_data=weights[index*36+l*9+t];
                @(negedge clk);load_valid=0;
            end
        end
    endtask
    task start;
        input integer index;
        begin
            @(negedge clk);tap_count=index%2==0 ? 1:9;initial_sums=initials[index];issues=0;expected_pairs=index%2==0 ? 8:72;start_valid=1;
            @(negedge clk);start_valid=0;tap_count=0;initial_sums=0;
            if(error || !busy)$fatal(1,"tile start failed");
        end
    endtask
    task finish;
        input integer index;
        begin
            wait(out_valid);@(negedge clk);
            if(out_sums!==golden[index] || issues!=(index%2==0 ? 8:72))$fatal(1,"tile result/issue mismatch index=%0d",index);
            repeat(15)@(negedge clk);
            out_ready=1;@(negedge clk);out_ready=0;
            if(busy)$fatal(1,"tile did not return idle");checked=checked+1;
        end
    endtask
    initial begin
        if(!$value$plusargs("JOBS=%d",jobs))$fatal(1,"missing jobs");
        $readmemh("inputs.mem",inputs,0,jobs*9-1);$readmemh("weights.mem",weights,0,jobs*36-1);
        $readmemh("initials.mem",initials,0,jobs-1);$readmemh("golden.mem",golden,0,jobs-1);
        repeat(4)@(negedge clk);rst_n=1;
        // 未装满缓存时拒绝启动；可以装载后重试。
        @(negedge clk);start_valid=1;@(negedge clk);start_valid=0;
        if(!error || busy)$fatal(1,"uninitialized cache accepted");
        for(job=0;job<jobs;job=job+1)begin
            load(job,job%3==0);start(job);
            if(job==1)begin wait(issues>=3);@(negedge clk);force_pause=1;repeat(70)@(negedge clk);force_pause=0;end
            finish(job);
        end
        load(0,1);start(0);wait(issues>=3);@(negedge clk);rst_n=0;
        repeat(4)@(negedge clk);rst_n=1;load(0,1);start(0);finish(0);
        $display("PASS mac_tile cases=%0d outputs=%0d",checked,checked*4);$finish;
    end
    initial begin #1000000;$fatal(1,"tile timeout");end
endmodule
