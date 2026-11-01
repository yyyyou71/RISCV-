`timescale 1ns/1ps
// Short real-CPU smoke test for the current SPI-only SPT1 service.
module TB_cpu_fspi #(parameter integer ENABLE_DUAL=0);
    reg clk=0,key_n=1,sck=1,cs=1,drive=0;
    reg [3:0] dq=0;
    wire [3:0] bus;
    assign bus=drive ? dq : 4'bzzzz;
    wire uart_tx,led0,led1;
    reg [7:0] request[0:255],reply[0:255];
    integer i,frames=0;
    reg [31:0] hash;
    always #20 clk=~clk;
    board_fspi_top #(.RESET_HOLD_CYCLES(8),.ENABLE_DUAL(ENABLE_DUAL)) dut(
        .sys_clk(clk),.key0_n(key_n),.uart_tx(uart_tx),.led0(led0),.led1(led1),
        .spi_clk(sck),.spi_cs(cs),.spi_data(bus));
    always @(posedge clk)
        if(dut.rst_n && dut.bus_err) $fatal(1,"CPU bus error");
    task put32;input integer at;input [31:0] value;begin
        request[at]=value[7:0];request[at+1]=value[15:8];
        request[at+2]=value[23:16];request[at+3]=value[31:24];
    end endtask
    function [31:0] get32;input integer at;begin
        get32={reply[at+3],reply[at+2],reply[at+1],reply[at]};
    end endfunction
    task nibble;input [3:0] value;begin
        sck=0;drive=1;dq=value;#10;sck=1;#10;
    end endtask
    task send;input [7:0] value;begin nibble(value[7:4]);nibble(value[3:0]);end endtask
    task recv;output [7:0] value;begin
        drive=0;sck=0;#10;sck=1;#1;value[7:4]=bus;#9;
        sck=0;#10;sck=1;#1;value[3:0]=bus;#9;
    end endtask
    task finish_frame;begin
        #3;cs=1;drive=0;#1100;
        if(bus!==4'bzzzz)$fatal(1,"DQ not released");
    end endtask
    task receive_frame;integer j,size;begin
        // Testbench observes ownership only to avoid pointless polling traffic.
        // All packet bytes still travel over the physical SPI pins.
        wait(dut.u_soc.u_peripheral_bus.g_fspi.u_fspi.tx_pending);
        #1100;cs=0;#7;send(8'h80);
        for(j=0;j<256;j=j+1)recv(reply[j]);
        finish_frame;
        if(get32(0)!==32'h31545053)$fatal(1,"SPT1 magic %h",get32(0));
        size=16+{reply[11],reply[10]};
        if(size>256)$fatal(1,"Invalid response size");
        hash=32'd2166136261;
        for(j=0;j<size;j=j+1)if(j<12 || j>=16)hash=(hash^reply[j])*32'd16777619;
        if(hash!==get32(12))$fatal(1,"Response checksum");
        frames=frames+1;
    end endtask
    task transaction;input [15:0] op;input [31:0] seq,value;
        integer j,size,attempts;reg found;begin
        for(j=0;j<256;j=j+1)request[j]=0;
        put32(0,32'h31545053);put32(4,seq);
        request[8]=op[7:0];request[9]=op[15:8];
        request[10]=(op==1)?8:4;put32(16,5);put32(20,value);
        size=16+request[10];hash=32'd2166136261;
        for(j=0;j<size;j=j+1)if(j<12 || j>=16)hash=(hash^request[j])*32'd16777619;
        put32(12,hash);
        wait(dut.u_soc.u_peripheral_bus.g_fspi.u_fspi.rx_armed);
        #1100;cs=0;#7;send(0);
        for(j=0;j<256;j=j+1)send(request[j]);
        finish_frame;found=0;attempts=0;
        while(!found && attempts<5)begin
            receive_frame;attempts=attempts+1;
            found=({reply[9],reply[8]}==16'h8003 && get32(4)==seq);
        end
        if(!found || get32(16)!==0 || get32(20)!==op || get32(24)!==32'h12345678)
            $fatal(1,"SPI service response op=%0d status=%h value=%h",op,get32(16),get32(24));
    end endtask
    initial begin
        // Pulse the board key after initial release, providing a definite reset
        // edge to the SPI domain even though SCK is stopped at power-up.
        wait(dut.rst_n);@(negedge clk);key_n=0;
        repeat(12)@(negedge clk);key_n=1;wait(dut.rst_n);
        transaction(1,1,32'h12345678);
        transaction(2,2,0);
        $display("PASS: CPU dual=%0d SPI-only SPT1 set/get, checksums, frames=%0d",ENABLE_DUAL,frames);
        $finish;
    end
    initial begin #30000000;
        $display("debug frames=%0d pc=%h rxarmed=%b txpending=%b index=%h proto=%b reject=%b",frames,
            dut.u_soc.u_core.pc,dut.u_soc.u_peripheral_bus.g_fspi.u_fspi.rx_armed,
            dut.u_soc.u_peripheral_bus.g_fspi.u_fspi.tx_pending,
            dut.u_soc.u_peripheral_bus.g_fspi.u_fspi.cpu_index,
            dut.u_soc.u_peripheral_bus.g_fspi.u_fspi.protocol_error,
            dut.u_soc.u_peripheral_bus.g_fspi.u_fspi.cpu_rejected);
        $fatal(1,"SPI-only CPU timeout");end
endmodule
