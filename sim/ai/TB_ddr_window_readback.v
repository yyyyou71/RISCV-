`timescale 1ns/1ps
// Independently supplied DDR data must replace the CPU window's stale payload.
// Run the identical stimulus against RTL and the PDS functional netlist.
module TB_ddr_window_readback;
    GTP_GRS GRS_INST(.GRS_N(1'b1));
    reg clk=0,core_clk=0,rst_n=0;
    always #20 clk=~clk;
    always #3.80952381 core_clk=~core_clk;
`ifdef GATE_NETLIST
    wire model_clk=dut.nt_core_clk;
`else
    wire model_clk=core_clk;
`endif
    reg dev_we=0;
    reg [31:0] dev_addr_wr=0,dev_addr_rd=0,dev_wdata=0;
    wire [31:0] read_data;
    wire [27:0] araddr,awaddr;
    wire arvalid,awvalid;
    wire [3:0] arlen,awlen;
    wire [127:0] wdata;
    wire [15:0] wstrb;
    reg active=0;
    reg [27:0] native_base=0;
    reg [4:0] beats=0,beat=0;
    integer cycle=0,read_commands=0,cases=0;
    wire arready=!active && cycle%3!=0;
    wire rvalid=active && cycle%5!=0;
    wire rlast=beat==beats-1;
    reg [127:0] rdata;
    integer lane;
    function [31:0] pattern;
        input [31:0] byte_address;
        begin pattern=byte_address^32'h314c4941;end
    endfunction
    always @* begin
        for(lane=0;lane<4;lane=lane+1)
            rdata[lane*32+:32]=pattern(({4'b0,native_base}<<1)+beat*16+lane*4);
    end
    ddr_cpu_window dut(
        .clk(clk),.core_clk(core_clk),.rst_n(rst_n),.ddr_init_done(1'b1),
        .pixclk_in(1'b0),.vs_in(1'b0),.de_in(1'b0),.rgb_in(24'b0),
        .dev_we(dev_we),.dev_addr_wr(dev_addr_wr),.dev_addr_rd(dev_addr_rd),
        .dev_wdata(dev_wdata),.read_data(read_data),
        .axi_awuser_ap(),.axi_aruser_ap(),.axi_awuser_id(),.axi_aruser_id(),
        .axi_awaddr(awaddr),.axi_awlen(awlen),.axi_awvalid(awvalid),.axi_awready(1'b0),
        .axi_wdata(wdata),.axi_wstrb(wstrb),.axi_wready(1'b0),
        .axi_wusero_id(4'b0),.axi_wusero_last(1'b0),
        .axi_araddr(araddr),.axi_arlen(arlen),.axi_arvalid(arvalid),.axi_arready(arready),
        .axi_rdata(rdata),.axi_rid(4'b0),.axi_rlast(rlast),.axi_rvalid(rvalid));
    always @(posedge model_clk) begin
        if(!rst_n)begin active<=0;cycle<=0;beat<=0;beats<=0;read_commands<=0;end
        else begin
            cycle<=cycle+1;
            if(arvalid && arready)begin
                if(araddr[2:0]!=0 || {1'b0,araddr[9:0]}+({1'b0,arlen}+1)*8>1024)
                    $fatal(1,"unsplit native read addr=%h len=%h",araddr,arlen);
                native_base<=araddr;beats<={1'b0,arlen}+1;beat<=0;active<=1;
                read_commands<=read_commands+1;
            end
            if(rvalid)begin
                if(rlast)active<=0;else beat<=beat+1;
            end
        end
    end
    task put;
        input [31:0] address,value;
        begin
            @(negedge clk);dev_we=1;dev_addr_wr=address;dev_wdata=value;
            @(posedge clk);#1;@(negedge clk);dev_we=0;
        end
    endtask
    task get;
        input [31:0] address;
        output [31:0] value;
        begin @(negedge clk);dev_addr_rd=address;#2;value=read_data;end
    endtask
    reg [31:0] value;
    integer n,k;
    task check_read;
        input [31:0] address;
        input integer length;
        integer word_index,polls;
        begin
            // Poison every CPU word; none of these writes reach external DDR.
            for(word_index=0;word_index<64;word_index=word_index+1)
                put(32'h31100+word_index*4,32'ha7a7a7a7);
            put(32'h31008,address);put(32'h3100c,length);put(32'h31000,1);
            begin: poll
                for(polls=0;polls<500;polls=polls+1)begin
                    get(32'h31004,value);
                    if(value[2] || value[3])$fatal(1,"window error status=%h",value);
                    if(!value[0] && value[1])disable poll;
                end
                $fatal(1,"read timeout");
            end
            for(word_index=0;word_index<length/4;word_index=word_index+1)begin
                get(32'h31100+word_index*4,value);
                if(value!==pattern(address+word_index*4))
                    $fatal(1,"READBACK_MISMATCH addr=%h word=%0d got=%h expected=%h",
                        address,word_index,value,pattern(address+word_index*4));
            end
            // A short reload must retain previously valid words outside it.
            if(length<256)begin
                get(32'h31100+length,value);
                if(value!==32'ha7a7a7a7)$fatal(1,"short reload changed another word");
            end
            cases=cases+1;
        end
    endtask
    initial begin
        repeat(6)@(negedge clk);rst_n=1;repeat(8)@(negedge clk);
        for(n=1;n<=16;n=n+1)check_read(32'h10000+(n-1)*4096,n*16);
        check_read(32'h7f0,256);
        check_read(32'h1fffff00,256);
        if(awvalid || wstrb!=0)$fatal(1,"readback test unexpectedly issued a write");
        $display("WINDOW_READBACK_PASS cases=%0d native_reads=%0d",cases,read_commands);
        $finish;
    end
    initial begin #10000000;$fatal(1,"global timeout");end
endmodule
