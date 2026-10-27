`timescale 1ns/1ps
// 原生IP模型的标准同步读时序：不允许把rd_data当成FWFT。
module TB_pango_video_fifo;
    reg wr_clk=0,rd_clk=0,wr_rst=1,rd_rst=1,wr_en=0,rd_en=0;
    reg [31:0] wr_data=0;
    wire [31:0] rd_data;
    wire full,empty,af,ae;
    wire [4:0] wl,rl;
    integer n;
    always #7 wr_clk=~wr_clk;
    always #11 rd_clk=~rd_clk;
    pango_video_fifo_model #(.DATA_WIDTH(32),.ADDR_WIDTH(4),.ALMOST_FULL_NUM(14),.ALMOST_EMPTY_NUM(2)) dut (
        .wr_clk(wr_clk),.wr_rst(wr_rst),.wr_en(wr_en),.wr_data(wr_data),.wr_full(full),.almost_full(af),.wr_water_level(wl),
        .rd_clk(rd_clk),.rd_rst(rd_rst),.rd_en(rd_en),.rd_data(rd_data),.rd_empty(empty),.almost_empty(ae),.rd_water_level(rl)
    );
    task push;
        input [31:0] value;
        begin
            @(negedge wr_clk);wr_en=1;wr_data=value;
            @(posedge wr_clk);#1;if(full && value!=15)$fatal(1,"premature full");
            @(negedge wr_clk);wr_en=0;
        end
    endtask
    initial begin
        // 显式产生复位边沿，使Icarus/Verilator都在活动时钟前完成初始复位。
        #1;wr_rst=0;rd_rst=0;#1;wr_rst=1;rd_rst=1;
        #40;wr_rst=0;rd_rst=0;#1;
        if(full || !empty || wl || rl || !ae)$fatal(1,"FIFO reset flags");
        @(negedge wr_clk);wr_en=1;wr_data=32'habcdef01;@(posedge wr_clk);#1;
        // 两级Gray同步后还要寄存状态，非空应在第三个读时钟沿出现。
        fork
            begin @(negedge wr_clk);wr_en=0;end
            begin
                for(n=1;n<=3;n=n+1)begin
                    @(posedge rd_clk);#1;
                    if(empty !== (n<3))$fatal(1,"empty CDC delay n=%0d empty=%b",n,empty);
                end
            end
        join
        if(rl!=1 || wl!=1)$fatal(1,"single word water level");
        @(negedge rd_clk);rd_en=1;@(posedge rd_clk);#1;
        if(rd_data!==32'habcdef01 || !empty || rl!=0)$fatal(1,"registered read data/last empty");
        @(negedge rd_clk);rd_en=0;repeat(4)@(posedge wr_clk);#1;
        if(wl!=0)$fatal(1,"read pointer failed to cross to writer");
        for(n=0;n<16;n=n+1)push(n);
        if(!full || !af || wl!=16)$fatal(1,"FIFO full/watermark");
        repeat(4)@(posedge rd_clk);#1;
        if(rl!=16 || empty || ae)$fatal(1,"FIFO read level");
        @(negedge rd_clk);rd_en=1;
        for(n=0;n<16;n=n+1)begin
            @(posedge rd_clk);#1;
            if(rd_data!==n || rl!=15-n || ae!==(n>=13))$fatal(1,"FIFO read/watermark n=%0d data=%h level=%0d",n,rd_data,rl);
        end
        @(negedge rd_clk);rd_en=0;
        repeat(5)@(posedge rd_clk);#1;
        if(!empty || rd_data!==15)$fatal(1,"output must hold without read");
        $display("PASS pango_fifo native_read=1 full_empty=1 cdc_delay=3 watermarks=1");$finish;
    end
    initial begin #100000;$fatal(1,"native FIFO timeout");end
endmodule

// 封装的连续供数/背压/绕圈，跨两个独立时钟核对5000个128位字。
module TB_video_fifo_adapter;
    reg wr_clk=0,rd_clk=0,rst_n=0,wr_en=0,rd_en=0;
    reg [127:0] wr_data=0;
    wire [127:0] rd_data;
    wire full,empty;
    wire [9:0] level;
    integer sent=0,received=0,wcycles=0,rcycles=0;
    reg [31:0] rng=32'h12345678;
    reg [127:0] held;
    always #3 wr_clk=~wr_clk;
    always #5 rd_clk=~rd_clk;
    video_async_fifo dut (.wr_clk(wr_clk),.wr_reset_n(rst_n),.wr_en(wr_en),.wr_data(wr_data),.full(full),
        .rd_clk(rd_clk),.rd_reset_n(rst_n),.rd_en(rd_en),.rd_data(rd_data),.empty(empty),.rd_level(level));
    function [127:0] pattern;
        input integer index;
        begin pattern={32'(index)^32'habcdef01,~32'(index),32'(index)+32'h10345678,32'(index)};end
    endfunction
    always @(negedge wr_clk) if(rst_n)begin
        wr_en=sent<5000 && ((wcycles%23)<19);wr_data=pattern(sent);wcycles=wcycles+1;
    end
    always @(posedge wr_clk)if(rst_n && wr_en && !full)sent=sent+1;
    always @(negedge rd_clk)if(rst_n)begin
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        // 先不读，强制写满；后续随机背压并覆盖多个指针绕圈。
        rd_en=rcycles>400 && (rng[2:0]!=0);rcycles=rcycles+1;
    end
    always @(posedge rd_clk)if(rst_n && !empty)begin
        if(rd_data!==pattern(received))$fatal(1,"prefetch order n=%0d got=%h",received,rd_data);
        if(rd_en)received=received+1;
        else begin
            held=rd_data;#1;
            if(empty || rd_data!==held)$fatal(1,"prefetch data changed under backpressure");
        end
    end
    initial begin
        #2;rst_n=1;#2;rst_n=0;#20;rst_n=1;
        wait(rcycles==400);#1;if(!full || sent!=513)$fatal(1,"expected512+1 FIFO capacity sent=%0d",sent);
        wait(received==5000);repeat(5)@(negedge rd_clk);
        if(!empty || level!=0 || sent!=received)$fatal(1,"FIFO not completely drained");
        $display("PASS video_fifo_adapter words=%0d backpressure=1 wraps=1",received);$finish;
    end
    initial begin #1000000;$fatal(1,"adapter FIFO timeout");end
endmodule
