`timescale 1ns/1ps
module TB_ai_control;
    reg clk=0,ref_clk=0,rst_n=0;
    always #20 clk=~clk;
    always #20 ref_clk=~ref_clk;
    wire core_clk,ddr_init_done,uart_txd;
    reg dev_we=0,dev_re=0;
    reg [31:0] dev_addr_wr=0,dev_addr_rd=0,dev_wdata=0;
    wire [31:0] dev_rdata;
    wire [27:0] axi_awaddr, axi_araddr;
    wire axi_awuser_ap, axi_aruser_ap, axi_awvalid, axi_arvalid;
    wire [3:0] axi_awuser_id, axi_aruser_id, axi_awlen, axi_arlen;
    wire axi_awready, axi_arready, axi_wready, axi_wusero_last;
    wire [3:0] axi_wusero_id, axi_rid;
    wire [127:0] axi_wdata, axi_rdata;
    wire [15:0] axi_wstrb;
    wire axi_rlast, axi_rvalid;


    peripheral_bus #(.ENABLE_DDR(1),.ENABLE_AI(1),.AI_ACT_WIDTH(8),.DDR_TIMEOUT_CYCLES(64)) u_bus (
        .clk(clk),.rst_n(rst_n),.dev_we(dev_we),.dev_re(dev_re),.dev_addr_wr(dev_addr_wr),
        .dev_addr_rd(dev_addr_rd),.dev_wdata(dev_wdata),.dev_size(2'b10),.dev_rdata(dev_rdata),
        .uart_txd(uart_txd),.core_clk(core_clk),.ddr_init_done(ddr_init_done),
        .rk_tx_data(), .rk_tx_valid(), .rk_tx_ready(1'b0),
        .rk_param_data(32'd0), .rk_param_update(1'b0), .gpio_out(),
        .pixclk_in(1'b0), .vs_in(1'b0), .de_in(1'b0), .rgb_in(24'd0),
        .axi_awaddr(axi_awaddr),
        .axi_awuser_ap(axi_awuser_ap),
        .axi_awuser_id(axi_awuser_id),
        .axi_awlen(axi_awlen),
        .axi_awvalid(axi_awvalid),
        .axi_awready(axi_awready),
        .axi_wdata(axi_wdata),
        .axi_wstrb(axi_wstrb),
        .axi_wready(axi_wready),
        .axi_wusero_id(axi_wusero_id),
        .axi_wusero_last(axi_wusero_last),
        .axi_araddr(axi_araddr),
        .axi_aruser_ap(axi_aruser_ap),
        .axi_aruser_id(axi_aruser_id),
        .axi_arlen(axi_arlen),
        .axi_arvalid(axi_arvalid),
        .axi_arready(axi_arready),
        .axi_rdata(axi_rdata),
        .axi_rid(axi_rid),
        .axi_rlast(axi_rlast),
        .axi_rvalid(axi_rvalid)
    );
    ddr3 memory (
        .ref_clk(ref_clk), .resetn(rst_n), .core_clk(core_clk), .ddr_init_done(ddr_init_done),
        .axi_awaddr(axi_awaddr), .axi_awuser_ap(axi_awuser_ap), .axi_awuser_id(axi_awuser_id),
        .axi_awlen(axi_awlen), .axi_awvalid(axi_awvalid), .axi_awready(axi_awready),
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



    reg [31:0] value;
    integer writes=0,before_writes,polls;
    always @(posedge core_clk) if(rst_n && axi_wready) writes=writes+1;
    task put;
        input [31:0] addr,data;
        begin @(negedge clk);dev_we=1;dev_addr_wr=addr;dev_wdata=data;@(negedge clk);dev_we=0;end
    endtask
    task get;
        input [31:0] addr;
        begin @(negedge clk);dev_re=1;dev_addr_rd=addr;@(negedge clk);value=dev_rdata;dev_re=0;end
    endtask
    task wait_idle;
        begin
            value=1;polls=0;
            while(value[0]) begin get(32'h30204);polls=polls+1;if(polls>10000)$fatal(1,"control timeout");end
        end
    endtask
    task reset_all;
        begin
            @(negedge clk);rst_n=0;dev_we=0;dev_re=0;
            repeat(6)@(negedge clk);rst_n=1;wait(ddr_init_done);repeat(6)@(negedge clk);
            get(32'h30204);if(value!==48)$fatal(1,"AI reset status mismatch");
        end
    endtask
    task configure;
        begin
            put(32'h30208,32'h7f0);put(32'h3020c,32'h1fff0);put(32'h30210,32'h40000);put(32'h30214,32'h807f0);
            put(32'h30218,32'h00010001);put(32'h3021c,32'h00010001);put(32'h30220,5);
        end
    endtask
    task seed;
        begin
            memory.store_word(28'h3f8,128'h55555555555555555555555555555501,16'hffff);
            memory.store_word(28'hfff8,128'h66666666666666666666666666666602,16'hffff);
            memory.store_word(28'h403f8,128'd0,16'hffff);memory.store_word(28'h40400,128'd0,16'hffff);
        end
    endtask
    task run_good;
        begin
            seed;configure;before_writes=writes;put(32'h30200,1);wait_idle;
            if(value[4:0]!==5'b10010 || writes-before_writes!=2)$fatal(1,"AI did not complete/wrote wrong length");
            get(32'h3022c);if(value!==8)$fatal(1,"MAC issue count mismatch");
            if(memory.load_word(28'h403f8)!==128'd2 || memory.load_word(28'h40400)!==128'd0)
                $fatal(1,"control recovery result mismatch");
        end
    endtask
    initial begin
        reset_all;configure;
        force memory.axi_arready=1'b0;put(32'h30200,1);
        get(32'h30204);if(!value[0])$fatal(1,"AI busy not immediate");
        // Independent IIC/FIFO access must not alter an in-flight AI request.
        put(32'h30400,32'ha5);get(32'h30404);
        if(value!==32'h101)$fatal(1,"AI/IIC MMIO alias or lost FIFO access");
        put(32'h3021c,0);put(32'h31000,3);put(32'h30200,4);
        wait_idle;
        if(value[5:0]!==6'b101100)$fatal(1,"AI fault did not cross to CPU %h",value);
        get(32'h30224);if(value!==12)$fatal(1,"AI native timeout code mismatch");
        put(32'h30200,4);put(32'h31000,1);get(32'h31004);
        if(value[5:0]!==6'b101100)$fatal(1,"fault was cleared without joint reset");
        @(negedge clk);rst_n=0;repeat(6)@(negedge clk);release memory.axi_arready;
        rst_n=1;wait(ddr_init_done);repeat(6)@(negedge clk);run_good;
        seed;configure;put(32'h30200,1);
        wait(u_bus.g_ddr.u_window.g_ai.u_engine.u_tile.issue_valid);
        reset_all;run_good;
        $display("PASS ai_control fault_cdc=1 reset_inflight=1 recovery=2 iic_coexist=1");$finish;
    end
    initial begin #5000000;$fatal(1,"global control timeout");end
endmodule
