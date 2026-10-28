`timescale 1ns/1ps
// 真实DDR行为模型 + 外设总线/真实RV32I；图像只假设为已解码的RGB像素流。
module TB_video_capture;
    parameter integer CPU_TEST=0;
    parameter integer FIFO_BITS=9;
    reg clk=0,ref_clk=0,rst_n=0,pixel_clk=0;
    integer cpu_half_ns=20,pixel_half_ns=5,test_case=0;
    reg pixel_enable=1;
    initial begin
        if($value$plusargs("cpu_half_ns=%d",cpu_half_ns)) begin end
        if($value$plusargs("pixel_half_ns=%d",pixel_half_ns)) begin end
        if($value$plusargs("CASE=%d",test_case)) begin end
    end
    always #(cpu_half_ns) clk=~clk;
    always #20 ref_clk=~ref_clk;
    always #(pixel_half_ns) if(pixel_enable) pixel_clk=~pixel_clk;else pixel_clk=0;
    reg vs=0,de=0;
    reg [23:0] rgb=0;
    reg host_we=0,host_re=0;
    reg [31:0] host_addr_wr=0,host_addr_rd=0,host_data=0;
    wire dev_we,dev_re;
    wire [31:0] dev_addr_wr,dev_addr_rd,dev_wdata,dev_rdata;
    wire [1:0] dev_size;
    wire core_clk,ddr_init_done,uart_txd;
    wire [27:0] axi_awaddr,axi_araddr;
    wire axi_awuser_ap,axi_aruser_ap,axi_awvalid,axi_arvalid;
    wire [3:0] axi_awuser_id,axi_aruser_id,axi_awlen,axi_arlen;
    wire axi_awready,axi_arready,axi_wready,axi_wusero_last;
    wire [3:0] axi_wusero_id,axi_rid;
    wire [127:0] axi_wdata,axi_rdata;
    wire [15:0] axi_wstrb;
    wire axi_rlast,axi_rvalid;
    wire video_owner;
    integer video_beats=0,video_commands=0,read_commands=0,captures=0;
    reg block_ddr=0;
    wire memory_awready;
    assign axi_awready=memory_awready && !block_ddr;
    generate if(CPU_TEST) begin : g_cpu
        wire bus_err;
        soc #(.ENABLE_DDR(1),.ENABLE_AI(1),.ENABLE_VIDEO(1),.VIDEO_FIFO_ADDR_BITS(FIFO_BITS),
              .DDR_TIMEOUT_CYCLES(256)) u_soc (
            .clk(clk),.rst_n(rst_n),.timer_irq(1'b0),.bus_err(bus_err),.uart_txd(uart_txd),
            .core_clk(core_clk),.ddr_init_done(ddr_init_done),
            .pixclk_in(pixel_clk),.vs_in(vs),.hs_in(1'b0),.de_in(de),
            .r_in(rgb[23:16]),.g_in(rgb[15:8]),.b_in(rgb[7:0]),
            .axi_awaddr(axi_awaddr),.axi_awuser_ap(axi_awuser_ap),.axi_awuser_id(axi_awuser_id),
            .axi_awlen(axi_awlen),.axi_awvalid(axi_awvalid),.axi_awready(axi_awready),
            .axi_wdata(axi_wdata),.axi_wstrb(axi_wstrb),.axi_wready(axi_wready),
            .axi_wusero_id(axi_wusero_id),.axi_wusero_last(axi_wusero_last),
            .axi_araddr(axi_araddr),.axi_aruser_ap(axi_aruser_ap),.axi_aruser_id(axi_aruser_id),
            .axi_arlen(axi_arlen),.axi_arvalid(axi_arvalid),.axi_arready(axi_arready),
            .axi_rdata(axi_rdata),.axi_rid(axi_rid),.axi_rlast(axi_rlast),.axi_rvalid(axi_rvalid)
        );
        assign dev_we=u_soc.dev_we;assign dev_re=u_soc.dev_re;
        assign dev_addr_wr=u_soc.dev_addr_wr;assign dev_addr_rd=u_soc.dev_addr_rd;
        assign dev_wdata=u_soc.dev_wdata;assign dev_rdata=u_soc.dev_rdata;assign dev_size=u_soc.dev_size;
        assign video_owner=u_soc.u_peripheral_bus.g_ddr.u_window.owner_video;
        always @(posedge clk) if(rst_n) begin
            if(bus_err)$fatal(1,"CPU bus error");
            if(dev_we && dev_addr_wr==32'h30300 && dev_wdata[0])captures=captures+1;
            if(dev_we && dev_addr_wr==32'h30000) begin
                if(dev_wdata!==1)$fatal(1,"CPU video test returned %0d",dev_wdata);
                if(video_beats!=12 || captures!=2 || read_commands==0)$fatal(1,"CPU did not capture/read two frames");
                $display("PASS video_cpu captures=%0d beats=%0d",captures,video_beats);$finish;
            end
        end
    end else begin : g_host
        assign dev_we=host_we;assign dev_re=host_re;assign dev_addr_wr=host_addr_wr;assign dev_addr_rd=host_addr_rd;
        assign dev_wdata=host_data;assign dev_size=2;assign video_owner=u_bus.g_ddr.u_window.owner_video;
        peripheral_bus #(.ENABLE_DDR(1),.ENABLE_AI(1),.ENABLE_VIDEO(1),.VIDEO_FIFO_ADDR_BITS(FIFO_BITS),
                         .DDR_TIMEOUT_CYCLES(256)) u_bus (
            .clk(clk),.rst_n(rst_n),.uart_txd(uart_txd),.dev_we(dev_we),.dev_re(dev_re),
            .dev_addr_wr(dev_addr_wr),.dev_addr_rd(dev_addr_rd),.dev_wdata(dev_wdata),.dev_size(dev_size),.dev_rdata(dev_rdata),
            .core_clk(core_clk),.ddr_init_done(ddr_init_done),.pixclk_in(pixel_clk),.vs_in(vs),.de_in(de),.rgb_in(rgb),
            .axi_awaddr(axi_awaddr),.axi_awuser_ap(axi_awuser_ap),.axi_awuser_id(axi_awuser_id),
            .axi_awlen(axi_awlen),.axi_awvalid(axi_awvalid),.axi_awready(axi_awready),
            .axi_wdata(axi_wdata),.axi_wstrb(axi_wstrb),.axi_wready(axi_wready),
            .axi_wusero_id(axi_wusero_id),.axi_wusero_last(axi_wusero_last),
            .axi_araddr(axi_araddr),.axi_aruser_ap(axi_aruser_ap),.axi_aruser_id(axi_aruser_id),
            .axi_arlen(axi_arlen),.axi_arvalid(axi_arvalid),.axi_arready(axi_arready),
            .axi_rdata(axi_rdata),.axi_rid(axi_rid),.axi_rlast(axi_rlast),.axi_rvalid(axi_rvalid)
        );
    end endgenerate
    // 本测试只连接DDR用户口；物理引脚和调试输出刻意不接。
    /* verilator lint_off PINMISSING */
    ddr3 memory (
        .ref_clk(ref_clk), .resetn(rst_n), .core_clk(core_clk), .ddr_init_done(ddr_init_done),
        .axi_awaddr(axi_awaddr), .axi_awuser_ap(axi_awuser_ap), .axi_awuser_id(axi_awuser_id),
        .axi_awlen(axi_awlen), .axi_awvalid(axi_awvalid && !block_ddr), .axi_awready(memory_awready),
        .axi_wdata(axi_wdata), .axi_wstrb(axi_wstrb), .axi_wready(axi_wready),
        .axi_wusero_id(axi_wusero_id), .axi_wusero_last(axi_wusero_last),
        .axi_araddr(axi_araddr), .axi_aruser_ap(axi_aruser_ap), .axi_aruser_id(axi_aruser_id),
        .axi_arlen(axi_arlen), .axi_arvalid(axi_arvalid), .axi_arready(axi_arready),
        .axi_rdata(axi_rdata), .axi_rid(axi_rid), .axi_rlast(axi_rlast), .axi_rvalid(axi_rvalid),
        .apb_clk(ref_clk), .apb_rst_n(rst_n), .apb_sel(1'b0), .apb_enable(1'b0),
        .apb_addr(8'd0), .apb_write(1'b0), .apb_wdata(16'd0),
        .dbg_gate_start(1'b0), .dbg_cpd_start(1'b0), .dbg_ddrphy_rst_n(1'b1),
        .dbg_gpll_scan_rst(1'b0), .samp_position_dyn_adj(1'b0), .wrcal_position_dyn_adj(1'b0),
        .init_samp_position_even(16'd0), .init_samp_position_odd(16'd0),
        .init_wrcal_position(16'd0), .init_slip_step(8'd0), .init_read_clk_ctrl(6'd0),
        .force_read_clk_ctrl(1'b0), .debug_cpd_offset_adj(1'b0),
        .debug_cpd_offset_dir(1'b0), .debug_cpd_offset(10'd0),
        .ck_dly_en(1'b0), .init_ck_dly_step(8'd0)
    );
    /* verilator lint_on PINMISSING */


    localparam [31:0] CTRL=32'h30300,STATUS=32'h30304,BASE=32'h30308,HW=32'h3030c,
        STRIDE=32'h30310,POLARITY=32'h30314,ERROR=32'h30318,BYTES=32'h3031c,TIMEOUT=32'h30320;
    reg [31:0] value;
    integer checks=0;
    task put;
        input [31:0] address,data;
        begin @(negedge clk);host_we=1;host_addr_wr=address;host_data=data;@(negedge clk);host_we=0;end
    endtask
    task get;
        input [31:0] address;
        output [31:0] data;
        begin @(negedge clk);host_re=1;host_addr_rd=address;@(negedge clk);data=dev_rdata;host_re=0;end
    endtask
    task wait_result;
        input [31:0] address;
        input integer code,fatal_expected;
        integer polls;
        reg [31:0] s,e;
        begin
            polls=0;s=1;
            while(s[0]) begin
                get(address,s);polls=polls+1;
                if(polls>50000)$fatal(1,"peripheral busy timeout captures=%0d checks=%0d",captures,checks);
            end
            get(address==STATUS?ERROR:32'h31010,e);
            if(s[3]!==fatal_expected[0] || s[2] !== (code!=0) || s[1] !== (code==0) || e!==code)
                $fatal(1,"status=%h code=%0d expected=%0d fatal=%0d",s,e,code,fatal_expected);
            checks=checks+1;
        end
    endtask
    task configure;
        input [31:0] address;
        input integer w,h,stride_bytes,polarity;
        begin
            put(BASE,address);put(HW,(h<<16)|w);put(STRIDE,stride_bytes);put(POLARITY,polarity);put(TIMEOUT,1000000);
        end
    endtask
    function [31:0] pixel;
        input integer x,y,seed;
        begin pixel=(((x+17+seed)&255)) | (((y+33+seed)&255)<<8) | (((x^y^85^seed)&255)<<16);end
    endfunction
    task vs_pulse;
        input integer polarity;
        begin
            @(negedge pixel_clk);de=0;vs=!polarity[0];repeat(3)@(negedge pixel_clk);
            vs=polarity[0];repeat(3)@(negedge pixel_clk);
            vs=!polarity[0];repeat(8)@(negedge pixel_clk);
        end
    endtask
    task send_frame;
        input integer w,h,seed,polarity;
        integer x,y;
        reg [31:0] p;
        begin
            vs_pulse(polarity);
            for(y=0;y<h;y=y+1) begin
                for(x=0;x<w;x=x+1) begin
                    @(negedge pixel_clk);de=1;p=pixel(x,y,seed);rgb={p[7:0],p[15:8],p[23:16]};
                end
                @(negedge pixel_clk);de=0;repeat(6)@(negedge pixel_clk);
            end
            repeat(8)@(negedge pixel_clk);if(!CPU_TEST)vs_pulse(polarity);
        end
    endtask
    task read_word;
        input [31:0] address;
        output [127:0] word;
        integer lane;
        reg [31:0] data;
        begin
            put(32'h31008,address);put(32'h3100c,16);put(32'h31000,1);wait_result(32'h31004,0,0);
            for(lane=0;lane<4;lane=lane+1) begin get(32'h31100+lane*4,data);word[lane*32+:32]=data;end
        end
    endtask
    task fill_region;
        input [31:0] address;
        input integer words;
        integer n,lane;
        begin
            for(lane=0;lane<4;lane=lane+1)put(32'h31100+lane*4,32'ha5a5a5a5);
            for(n=0;n<words;n=n+1) begin
                put(32'h31008,address+n*16);put(32'h3100c,16);put(32'h31000,3);wait_result(32'h31004,0,0);
            end
        end
    endtask
    reg check_payload=0;
    reg [31:0] expected_base=0;
    integer expected_width=0,expected_height=0,expected_stride=0,expected_seed=0;
    reg [31:0] bus_address;
    reg [127:0] expected_word;
    integer offset,yy,xx,lane;
    always @(posedge core_clk) if(rst_n) begin
        if(axi_arvalid && axi_arready) begin
            read_commands=read_commands+1;
            if(video_owner)$fatal(1,"capture generated DDR read");
        end
        if(video_owner && axi_awvalid && axi_awready) begin
            bus_address={3'd0,axi_awaddr,1'b0};video_commands=video_commands+1;
            if(bus_address[10:0]+(32'(axi_awlen)+1)*16>2048)$fatal(1,"burst crossed column wrap");
        end
        if(video_owner && axi_wready) begin
            video_beats=video_beats+1;
            if(axi_wstrb!==16'hffff)$fatal(1,"capture byte mask");
            if(check_payload) begin
                offset=bus_address-expected_base;yy=offset/expected_stride;xx=(offset%expected_stride)/4;
                if(offset<0 || yy>=expected_height || xx>=((expected_width+3)&~3))$fatal(1,"capture wrote outside rows");
                for(lane=0;lane<4;lane=lane+1)
                    expected_word[lane*32+:32]=(xx+lane<expected_width)?pixel(xx+lane,yy,expected_seed):0;
                if(axi_wdata!==expected_word)$fatal(1,"pixel/order mismatch addr=%h got=%h expected=%h",bus_address,axi_wdata,expected_word);
            end
            bus_address=bus_address+16;
        end
    end
    reg [127:0] readback,expected;
    task success;
        input [31:0] address;
        input integer w,h,stride_bytes,seed,polarity;
        integer before_beats,n,x,y,l,extent;
        begin
            extent=(h-1)*stride_bytes+((w+3)/4)*16;
            fill_region(address-16,extent/16+2);
            configure(address,w,h,stride_bytes,polarity);
            expected_base=address;expected_width=w;expected_height=h;expected_stride=stride_bytes;expected_seed=seed;
            check_payload=1;before_beats=video_beats;
            put(CTRL,1);repeat(12)@(negedge pixel_clk);
            // 忙时CPU窗口、AI和视频配置/再次启动全部忽略，不得抢走DDR所有权。
            put(BASE,32'h1000);put(32'h31000,3);put(32'h30200,1);put(CTRL,1);
            get(BASE,value);if(value!==address)$fatal(1,"busy config changed");
            send_frame(w,h,seed,polarity);wait_result(STATUS,0,0);
            get(BYTES,value);if(value!==h*((w+3)/4)*16)$fatal(1,"written bytes=%0d",value);
            if(video_beats-before_beats!=h*((w+3)/4))$fatal(1,"missing/extra writes");
            before_beats=video_beats;send_frame(w,h,seed+1,polarity);
            if(video_beats!=before_beats)$fatal(1,"idle frame was captured");
            check_payload=0;
            for(n=-16;n<extent+16;n=n+16) begin
                expected={4{32'ha5a5a5a5}};
                if(n>=0 && n<extent) begin
                    y=n/stride_bytes;x=(n%stride_bytes)/4;
                    if(x<((w+3)&~3))for(l=0;l<4;l=l+1)expected[l*32+:32]=(x+l<w)?pixel(x+l,y,seed):0;
                end
                read_word(address+32'(n),readback);
                if(readback!==expected)$fatal(1,"DDR/guard mismatch addr=%h got=%h expected=%h",address+32'(n),readback,expected);
            end
            captures=captures+1;
        end
    endtask
    task invalid;
        input [31:0] address;
        input integer w,h,stride_bytes,code;
        integer before_count;
        begin
            before_count=video_commands;configure(address,w,h,stride_bytes,1);put(CTRL,1);wait_result(STATUS,code,0);
            if(video_commands!=before_count)$fatal(1,"invalid capture touched DDR");
        end
    endtask
    task bad_frame;
        input integer w,h;
        begin
            configure(32'h10000,7,3,32,1);put(CTRL,1);repeat(12)@(negedge pixel_clk);
            send_frame(w,h,0,1);wait_result(STATUS,4,0);
        end
    endtask
    task short_ai;
        integer n,polls;
        begin
            // 通过CPU窗口装载1x1卷积：输入1、权重2，核对输出2。
            for(n=0;n<4;n=n+1)put(32'h31100+n*4,n==0?1:0);
            put(32'h31008,32'h60000);put(32'h3100c,16);put(32'h31000,3);wait_result(32'h31004,0,0);
            for(n=0;n<4;n=n+1)put(32'h31100+n*4,n==0?2:0);
            put(32'h31008,32'h61000);put(32'h31000,3);wait_result(32'h31004,0,0);
            put(32'h30208,32'h60000);put(32'h3020c,32'h61000);put(32'h30214,32'h62000);
            put(32'h30218,32'h10001);put(32'h3021c,32'h10001);put(32'h30220,5);put(32'h30200,1);
            put(CTRL,1); // AI任务忙时必须忽略视频请求。
            value=1;polls=0;
            while(value[0])begin get(32'h30204,value);polls=polls+1;if(polls>10000)$fatal(1,"AI timeout");end
            if((value&15)!=2)$fatal(1,"AI owner failed: %h",value);
            read_word(32'h62000,readback);if(readback!==128'd2)$fatal(1,"AI output mismatch");
        end
    endtask
    initial begin
        #200;rst_n=1;wait(ddr_init_done);repeat(12)@(negedge clk);
        if(CPU_TEST) begin
            forever begin
                // 软件请求可能落在帧中间；仅下一完整帧能作为结果。
                send_frame(7,3,0,1);repeat(5000)@(negedge pixel_clk);
            end
        end else if(test_case==0) begin
            // 未发命令的输入必须全部丢弃。
            send_frame(7,3,9,1);if(video_beats!=0)$fatal(1,"captured without CPU request");
            success(32'h7f0,7,3,48,1,1);
            success(32'h20000,81,5,352,2,1);
            @(negedge pixel_clk);vs=1;repeat(5)@(negedge pixel_clk);
            success(32'h10000000,1,1,16,3,0);
            success(32'h1fffffb0,5,2,32,4,1);
            invalid(32'h1000,0,3,32,1);invalid(32'h1000,7,0,32,1);
            invalid(32'h1000,4097,1,32768,1);invalid(32'h1000,7,3,16,1);
            invalid(32'h1001,7,3,32,2);invalid(32'h1000,7,3,33,2);
            invalid(32'h1ffffff0,7,3,32,3);invalid(32'hfffffff0,7,3,32,3);
            bad_frame(6,3);bad_frame(8,3);bad_frame(7,2);bad_frame(7,4);
            short_ai;
            success(32'h40000,7,3,32,5,1);
            // 事务中途共同复位，所有指针/邮箱随DDR一起复位，之后能重新抓帧。
            configure(32'h50000,7,3,32,1);put(CTRL,1);repeat(12)@(negedge pixel_clk);
            vs_pulse(1);@(negedge pixel_clk);de=1;rgb=24'h123456;repeat(5)@(negedge pixel_clk);
            #1;rst_n=0;de=0;vs=0;#200;rst_n=1;wait(ddr_init_done);repeat(12)@(negedge clk);
            success(32'h50000,7,3,32,6,1);
            $display("PASS video_host captures=%0d checks=%0d native_beats=%0d",captures,checks,video_beats);$finish;
        end else if(test_case==1) begin
            configure(32'h1000,1024,4,4096,1);put(CTRL,1);repeat(12)@(negedge pixel_clk);
            send_frame(1024,4,0,1);wait_result(STATUS,5,0);
            // 溢出后必须丢净旧帧，再用同一个FIFO成功抓取一张小图。
            success(32'h10000,3,2,16,7,1);
            $display("PASS video_overflow_recovery checks=%0d",checks);$finish;
        end else if(test_case==2 || test_case==3) begin
            configure(32'h1000,7,3,32,1);put(TIMEOUT,256);put(CTRL,1);
            if(test_case==3)begin repeat(12)@(negedge pixel_clk);pixel_enable=0;end
            wait_result(STATUS,6,1);
            if(video_commands!=0)$fatal(1,"timeout generated DDR writes");
            put(CTRL,4);get(STATUS,value);if(!value[3] || value[4])$fatal(1,"fault cleared without reset");
            $display("PASS video_input_timeout case=%0d",test_case);$finish;
        end else if(test_case==4) begin
            configure(32'h1000,7,3,32,1);block_ddr=1;put(CTRL,1);repeat(12)@(negedge pixel_clk);
            send_frame(7,3,0,1);wait_result(STATUS,7,1);
            $display("PASS video_ddr_timeout");$finish;
        end else if(test_case==5) begin
            configure(32'h1000,7,3,32,1);put(TIMEOUT,100);block_ddr=1;put(CTRL,1);
            fork
                begin repeat(12)@(negedge pixel_clk);send_frame(7,3,0,1);end
                begin
                    wait(axi_awvalid);repeat(120)@(posedge core_clk);
                    get(STATUS,value);if(!value[0])$fatal(1,"released DDR owner in an unfinished burst");
                    block_ddr=0;
                end
            join
            wait_result(STATUS,6,1);get(BYTES,value);
            if(video_commands!=1 || value!=32)$fatal(1,"timeout did not finish exactly its current block");
            $display("PASS video_timeout_drains_active_burst");$finish;
        end
    end
    initial begin #20000000;$fatal(1,"global timeout");end
endmodule
