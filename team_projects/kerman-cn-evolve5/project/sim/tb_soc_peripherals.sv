`timescale 1ns/1ps
module tb_soc_peripherals;
    localparam UART=32'h40000000, GPIO=32'h40001000, TIMER=32'h40002000, RAM=32'h20000000;
    localparam integer BIT_NS=160; // 100 MHz clock / 16 cycles per UART bit
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1,iv=0,dv=0,dw=0,rx=1;
    reg [31:0] ia=0,da=0,wd=0;
    reg [3:0] ws=0;
    wire ir,ie,dr,de,tx,pending;
    wire [31:0] idata,rdata;
    wire [7:0] gpio_out,gpio_oe;
    rv32_soc_fabric #(.CLOCK_HZ(100000000),.BAUD(6250000),.ROM_FILE("unit_rom.hex")) dut (
        .clk(clk),.rst(rst),.iv(iv),.ia(ia),.ir(ir),.idata(idata),.ie(ie),
        .dv(dv),.dw(dw),.da(da),.wd(wd),.ws(ws),.dr(dr),.rdata(rdata),.de(de),
        .uart_rx(rx),.uart_tx(tx),.gpio_in(8'ha6),.gpio_out(gpio_out),.gpio_oe(gpio_oe),.timer_pending(pending)
    );
    integer checks=0,transactions=0,last_wait,tx_count=0;
    reg [7:0] tx_bytes [0:31];
    reg [7:0] observed;
    integer bitno,n;
    reg [31:0] value,other;

    task automatic check_group(input string label);
        begin checks=checks+1; $display("PERIPHERAL_CHECK %s",label); end
    endtask
    task automatic access(input bit wr,input reg [31:0] address,input reg [31:0] data,
                          input reg [3:0] mask,input bit expected_error,output reg [31:0] result);
        integer timeout;
        begin
            @(negedge clk); dv=1; dw=wr; da=address; wd=data; ws=mask; timeout=0;
            begin : wait_response
                forever begin
                    @(posedge clk);
                    if (dr) begin
                        result=rdata;
                        if (de !== expected_error) $fatal(1,"Bus error mismatch addr=%08x write=%0d got=%b",address,wr,de);
                        disable wait_response;
                    end
                    timeout=timeout+1;
                    if (timeout > 100000) $fatal(1,"Peripheral transaction timeout addr=%08x",address);
                end
            end
            last_wait=timeout; transactions=transactions+1;
            @(negedge clk); dv=0; dw=0; ws=0;
        end
    endtask
    task automatic read_expect(input reg [31:0] address,input reg [31:0] expected);
        reg [31:0] result;
        begin
            access(0,address,0,0,0,result);
            if (result !== expected) $fatal(1,"Read mismatch addr=%08x actual=%08x expected=%08x",address,result,expected);
        end
    endtask
    task automatic put(input reg [31:0] address,input reg [31:0] data,input reg [3:0] mask);
        reg [31:0] unused;
        begin access(1,address,data,mask,0,unused); end
    endtask
    task automatic send_byte(input reg [7:0] data,input real scale,input bit bad_stop);
        integer b;
        begin
            #23; rx=0; #(BIT_NS*scale);
            for(b=0;b<8;b=b+1) begin rx=data[b]; #(BIT_NS*scale); end
            rx=!bad_stop; #(BIT_NS*scale); rx=1; #(BIT_NS);
        end
    endtask
    initial forever begin
        @(negedge tx);
        if (!rst) begin
            #(BIT_NS*1.5);
            for(bitno=0;bitno<8;bitno=bitno+1) begin observed[bitno]=tx; #(BIT_NS); end
            if (tx !== 1) $fatal(1,"Unit UART stop bit failed");
            tx_bytes[tx_count]=observed; tx_count=tx_count+1;
        end
    end

    initial begin
        repeat(5) @(posedge clk);
        @(negedge clk); rst=0;
        read_expect(0,32'h11223344); if (last_wait < 1) $fatal(1,"ROM read was not clocked");
        @(negedge clk); iv=1; ia=4;
        @(posedge clk); if (ir) $fatal(1,"Instruction port responded before clocked read");
        @(posedge clk); if (!ir || ie || idata !== 32'h55667788) $fatal(1,"Instruction ROM read failed");
        @(negedge clk); iv=0;
        check_group("clocked_rom_dual_ports");

        put(RAM,32'h12345678,4'hf); read_expect(RAM,32'h12345678);
        put(RAM+1,32'h0000ab00,4'h2); read_expect(RAM,32'h1234ab78);
        put(RAM+2,32'hcdef0000,4'hc); read_expect(RAM,32'hcdefab78);
        put(RAM,32'hffffffff,4'h0); read_expect(RAM,32'hcdefab78);
        check_group("ram_word_byte_halfword_masks");
        access(1,0,32'hdeadbeef,15,1,value); read_expect(0,32'h11223344);
        check_group("rom_write_protection");
        @(negedge clk); iv=1; ia=RAM;
        @(posedge clk); @(posedge clk);
        if (!ir || !ie || idata != 0) $fatal(1,"Non-ROM fetch must fault");
        @(negedge clk); iv=0;
        access(0,32'h50000000,0,0,1,value);
        access(1,RAM+32768,123,15,1,value);
        check_group("unmapped_data_and_nonexecutable_ram");

        put(GPIO+4,8'hff,15); put(GPIO,8'h12,15);
        put(GPIO+12,8'h81,15); put(GPIO+16,8'h10,15); put(GPIO+20,8'h3c,15);
        read_expect(GPIO,8'hbf); read_expect(GPIO+4,8'hff); read_expect(GPIO+8,8'ha6);
        put(GPIO+1,32'h0000ff00,2); read_expect(GPIO,8'hbf);
        if (gpio_out != 8'hbf || gpio_oe != 8'hff) $fatal(1,"GPIO pins differ from registers");
        check_group("gpio_atomic_ops_masks_and_pins");
        access(1,GPIO+8,0,15,1,value); access(0,GPIO+12,0,0,1,value);
        access(0,GPIO+24,0,0,1,value);
        check_group("gpio_access_rights");

        read_expect(TIMER,0); read_expect(TIMER+4,0);
        put(TIMER,32'hfffffffc,15); put(TIMER+4,0,15); put(TIMER+16,1,15);
        repeat(12) @(posedge clk);
        put(TIMER+16,0,15); read_expect(TIMER+4,1);
        access(0,TIMER,0,0,0,value); if (value > 32) $fatal(1,"Timer rollover low word wrong");
        check_group("timer_64bit_rollover");
        put(TIMER+16,1,15); access(1,TIMER,0,15,1,value);
        put(TIMER+16,0,15); access(1,TIMER+20,0,15,1,value);
        check_group("timer_access_rights");
        put(TIMER,0,15); put(TIMER+4,0,15); put(TIMER+8,40,15); put(TIMER+12,0,15);
        put(TIMER+16,3,15); read_expect(TIMER+20,0);
        repeat(45) @(posedge clk); read_expect(TIMER+20,1);
        put(TIMER+16,1,15); read_expect(TIMER+20,0); put(TIMER+16,0,15);
        check_group("timer_compare_and_ack");

        read_expect(UART+8,16); read_expect(UART+4,1); read_expect(UART+12,0);
        access(1,UART+8,0,15,1,value); access(1,UART+8,65536,15,1,value);
        read_expect(UART+8,16);
        put(UART+8,32'h100,2); read_expect(UART+8,272); put(UART+8,16,15);
        access(1,UART+12,0,15,1,value); access(1,UART+1,0,2,1,value);
        access(0,UART+16,0,0,1,value);
        check_group("uart_divisor_masks_and_invalid_access");
        put(UART,8'h55,1); put(UART,8'ha6,15);
        if (last_wait < 100) $fatal(1,"Busy TX did not backpressure second write");
        wait(tx_count == 2);
        if (tx_bytes[0] != 8'h55 || tx_bytes[1] != 8'ha6) $fatal(1,"TX serialization data mismatch");
        repeat(20) @(posedge clk); read_expect(UART+4,1);
        check_group("uart_tx_serialization_and_backpressure");
        send_byte(8'h00,1.0,0); read_expect(UART,0);
        send_byte(8'hff,0.98,0); read_expect(UART,8'hff);
        send_byte(8'h55,1.02,0); read_expect(UART,8'h55);
        send_byte(8'haa,1.0,0); read_expect(UART,8'haa);
        check_group("uart_rx_values_and_clock_skew");
        for(n=0;n<5;n=n+1) send_byte(8'h10+n,1.0,0);
        read_expect(UART+12,4); access(0,UART+4,0,0,0,value);
        if (!(value & 4)) $fatal(1,"RX overrun flag absent");
        for(n=0;n<4;n=n+1) read_expect(UART,8'h10+n);
        put(UART+4,4,1); read_expect(UART+4,1);
        check_group("uart_fifo_overrun_drop_new_and_w1c");

        for(n=0;n<4;n=n+1) send_byte(8'h20+n,1.0,0);
        fork
            send_byte(8'h77,1.0,0);
            begin
                wait(dut.uart.receive_pulse);
                read_expect(UART,8'h20);
            end
        join
        for(n=1;n<4;n=n+1) read_expect(UART,8'h20+n);
        read_expect(UART,8'h77); read_expect(UART+4,1);
        check_group("uart_full_fifo_simultaneous_push_pop");

        send_byte(8'h5a,1.0,1); repeat(20) @(posedge clk);
        read_expect(UART+12,0); access(0,UART+4,0,0,0,value);
        if (!(value & 8)) $fatal(1,"Framing error flag absent");
        put(UART+4,8,1); read_expect(UART+4,1);
        send_byte(8'hc7,1.0,0); read_expect(UART,8'hc7);
        check_group("uart_framing_error_recovery");
        rx=0; #10; rx=1; repeat(25) @(posedge clk);
        read_expect(UART+12,0); read_expect(UART+4,1);
        check_group("uart_short_start_glitch_rejected");
        fork
            begin access(0,UART,0,0,0,value); if (value != 8'hc3 || last_wait < 20) $fatal(1,"Blocking RX read failed"); end
            begin repeat(25) @(posedge clk); send_byte(8'hc3,1.0,0); end
        join
        check_group("uart_empty_read_backpressure");

        // Cancel a captured RAM write before its completion edge.
        @(negedge clk); dv=1; dw=1; da=RAM; wd=32'hbad0bad0; ws=15;
        @(posedge clk);
        @(negedge clk); rst=1;
        @(posedge clk); #1;
        if (gpio_oe != 0 || gpio_out != 0 || tx != 1 || pending) $fatal(1,"Peripheral reset state wrong");
        @(negedge clk); dv=0; dw=0; rst=0;
        read_expect(RAM,32'hcdefab78);
        check_group("reset_cancels_pending_store_and_resets_peripherals");
        $display("PERIPHERALS_PASS groups=%0d transactions=%0d",checks,transactions);
        $finish;
    end
    initial begin #2000000; $fatal(1,"Peripheral test global timeout"); end
endmodule
