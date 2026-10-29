`timescale 1ns/1ps
module TB_pcie_mwr;
    reg clk=0, rst_n=0, req=0, ready=0;
    reg [19:0] length=32;
    wire ack, busy, valid, last, user_ready;
    wire [127:0] data, source_data;
    wire source_valid, sufficient;
    integer beats=0, packets=0, payloads=0, cycle=0;
    reg in_packet=0, stalled=0;
    reg [127:0] held_data;
    reg held_last;
    always #4 clk=~clk;
    pcie_test_source source(.rst_n(rst_n), .data(source_data),
        .valid(source_valid), .sufficient(sufficient));
    ips2l_pcie_dma_mwr_tx_ctrl dut(
        .clk(clk), .rst_n(rst_n),
        .i_cfg_pbus_num(8'h01), .i_cfg_pbus_dev_num(5'h00),
        .i_cfg_max_payload_size(3'd0), .i_user_define_data_flag(1'b1),
        .i_mwr32_req(1'b0), .o_mwr32_req_ack(),
        .i_mwr64_req(req), .o_mwr64_req_ack(ack),
        .i_req_length(length), .i_req_addr(64'h00000001_00001000),
        .i_req_data(32'b0), .o_rd_en(), .o_rd_length(),
        .i_gen_tlp_start(1'b0), .i_rd_data(128'b0), .i_last_data(1'b0),
        .i_axis_slave2_trdy(ready), .o_axis_slave2_tvld(valid),
        .o_axis_slave2_tdata(data), .o_axis_slave2_tlast(last),
        .o_axis_slave2_tuser(), .o_mwr_tx_busy(busy),
        .o_mwr_tx_hold(), .o_mwr_tlp_tx(), .i_tx_restart(1'b0),
        .i_dma_soft_rst(1'b0), .i_user_data(source_data),
        .i_user_data_vld(source_valid), .o_user_data_rdy(user_ready),
        .i_user_data_last(1'b0), .i_fifo_data_sufficient(sufficient));
    // Periodic downstream backpressure exercises header/payload stability.
    always @(negedge clk) begin
        cycle=cycle+1;
        ready=rst_n && ((cycle % 7) >= 2);
    end
    always @(posedge clk) if(rst_n) begin
        if(stalled && (!valid || data !== held_data || last !== held_last))
            $fatal(1,"TLP changed while stalled");
        stalled=valid && !ready;
        held_data=data; held_last=last;
        if(valid && ready) begin
            if(!in_packet) begin
                if(data[31:24] !== 8'h60 || data[9:0] !== 10'd32 || last)
                    $fatal(1,"Invalid 64-bit MWr header: %h",data);
                if(data[127:96] !== (32'h1000 + packets*128) || data[95:64] !== 32'h1)
                    $fatal(1,"Incorrect DMA destination address: %h",data);
                in_packet=1; beats=0;
            end else begin
                if(data !== {4{32'h00f800f8}})
                    $fatal(1,"Incorrect payload byte order: %h",data);
                beats=beats+1; payloads=payloads+1;
                if(last !== (beats==8)) $fatal(1,"Incorrect last/count");
                if(last) begin in_packet=0; packets=packets+1; end
            end
        end
    end
    initial begin
        repeat(5) @(negedge clk); rst_n=1;
        // 64 DWORDs = 256 bytes, split into two 128-byte TLPs.
        length=64; req=1;
        wait(ack); @(posedge clk); @(negedge clk); req=0;
        wait(busy); wait(!busy);
        repeat(5) @(negedge clk);
        if(packets!=2 || payloads!=16 || in_packet)
            $fatal(1,"Incorrect transfer totals packets=%0d payloads=%0d",packets,payloads);
        rst_n=0; repeat(5) @(negedge clk);
        if(busy!==0 || valid!==0 || source_valid!==0) $fatal(1,"Reset failed");
        $display("PASS: DMA MWr64 split, address advance, payload endian, backpressure, reset");
        $finish;
    end
    initial begin #100000; $fatal(1,"DMA timeout"); end
endmodule
