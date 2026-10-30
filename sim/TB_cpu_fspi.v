`timescale 1ns/1ps
module TB_cpu_fspi;
    reg clk=0, key0_n=0, scl=1, sda_low=0;
    reg spi_clk=0, spi_cs=1, drive=0;
    reg [3:0] dq=0;
    wire [3:0] spi_data;
    reg [7:0] spi_value;
    integer k;
    assign spi_data=drive ? dq : 4'bzzzz;
    tri1 sda;
    wire uart_tx, led0, led1;
    reg [7:0] value;
    integer updates=0;
    assign sda = sda_low ? 1'b0 : 1'bz;
    always #20 clk=~clk;
    board_fspi_top #(.RESET_HOLD_CYCLES(8), .ENABLE_FSPI(1)) dut (
        .sys_clk(clk), .key0_n(key0_n), .uart_tx(uart_tx),
        .led0(led0), .led1(led1), .iic_scl(scl), .iic_sda(sda),
        .spi_clk(spi_clk), .spi_cs(spi_cs), .spi_data(spi_data)
    );
    always @(posedge clk) begin
        if (!dut.rst_n) updates=0;
        else begin
            if (dut.rk_param_update) updates=updates+1;
            if (dut.bus_err) $fatal(1, "Unmapped CPU access during I2C test");
        end
    end
    task start_bus; begin
        scl=0; sda_low=0; #2500; scl=1; #2500; sda_low=1; #2500; scl=0; #2500;
    end endtask
    task stop_bus; begin
        scl=0; sda_low=1; #2500; scl=1; #2500; sda_low=0; #5000;
    end endtask
    task write_byte; input [7:0] data; input expect_ack; integer i; begin
        for(i=7;i>=0;i=i-1) begin
            scl=0; sda_low=!data[i]; #2500; scl=1; #5000; scl=0; #2500;
        end
        sda_low=0; #2500; scl=1; #2500;
        if(sda !== !expect_ack) $fatal(1, "ACK mismatch byte=%h sda=%b",data,sda);
        #2500; scl=0; #2500;
    end endtask
    task read_byte; output [7:0] data; integer i; begin
        sda_low=0;
        for(i=7;i>=0;i=i-1) begin
            #2500; scl=1; #2500; data[i]=sda; #2500; scl=0; #2500;
        end
        // NACK the final byte.
        sda_low=0; #2500; scl=1; #5000; scl=0; #2500;
    end endtask
    task write_reg; input [7:0] addr,data; begin
        start_bus; write_byte(8'hcc,1); write_byte(addr,1); write_byte(data,1); stop_bus;
    end endtask
    task read_reg; input [7:0] addr; output [7:0] data; begin
        start_bus; write_byte(8'hcc,1); write_byte(addr,1);
        start_bus; write_byte(8'hcd,1); read_byte(data); stop_bus;
    end endtask
    task expect_reg; input [7:0] addr,expected; reg [7:0] actual; begin
        read_reg(addr,actual);
        if(actual !== expected)
            $fatal(1,"Register %h: expected %h got %h",addr,expected,actual);
    end endtask
    task reset_board; begin
        scl=1; sda_low=0;
        @(negedge clk); key0_n=0;
        repeat(10) @(negedge clk);
        key0_n=1;
        wait(dut.rst_n === 1'b1);
        repeat(10) @(negedge clk);
    end endtask
    task wait_data; integer tries; reg [7:0] count; begin
        tries=0; count=0;
        while(count==0 && tries<30) begin read_reg(8'h20,count); tries=tries+1; end
        if(count!==1) $fatal(1,"CPU did not enqueue data");
    end endtask
    task receive_expected; input [7:0] expected; begin
        wait_data;
        expect_reg(8'h21,expected);
        expect_reg(8'h21,expected); // repeated read must not consume
        write_reg(8'h22,1);
    end endtask
    task nibble;input [3:0] n;begin
        drive=1;dq=n;#500;spi_clk=1;#500;spi_clk=0;
    end endtask
    task spi_send;input [7:0] v;begin nibble(v[7:4]);nibble(v[3:0]);end endtask
    task spi_recv;output [7:0] v;begin
        drive=0;#500;spi_clk=1;#1;v[7:4]=spi_data;#499;spi_clk=0;
        #500;spi_clk=1;#1;v[3:0]=spi_data;#499;spi_clk=0;
    end endtask
    task command;input [31:0] v;begin
        write_reg(8'h10,v[7:0]);write_reg(8'h11,v[15:8]);
        write_reg(8'h12,v[23:16]);write_reg(8'h13,v[31:24]);write_reg(8'h14,1);
    end endtask
    task response;input [7:0] code;input [31:0] v;begin
        receive_expected(code);receive_expected(v[7:0]);receive_expected(v[15:8]);
        receive_expected(v[23:16]);receive_expected(v[31:24]);
    end endtask
    initial begin
        reset_board;response(8'h52,256);
        command(32'h5a);response(8'h50,256);
        spi_cs=0;#1100;spi_send(8'h80);drive=0;
        for(k=0;k<256;k=k+1) begin
            spi_recv(spi_value);
            if(spi_value!==(k[7:0]^8'h5a)) $fatal(1,"CPU publication mismatch %0d",k);
        end
        spi_cs=1;#1100;
        spi_cs=0;drive=1;#1100;spi_send(0);
        for(k=0;k<256;k=k+1) spi_send(k[7:0]);
        spi_cs=1;drive=0;#1100;
        command(32'h80000000);response(8'h43,32640);
        expect_reg(8'h20,0);
        $display("PASS: real RV32 -> FSPI 256B, RK FSPI -> CPU checksum, IIC coordination, no bus errors");
        $finish;
    end
    initial begin #100000000; $fatal(1,"Board I2C test timeout"); end
endmodule
