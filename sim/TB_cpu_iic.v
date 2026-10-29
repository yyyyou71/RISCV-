`timescale 1ns/1ps
module TB_cpu_iic;
    reg clk=0, key0_n=0, scl=1, sda_low=0;
    tri1 sda;
    wire uart_tx, led0, led1;
    reg [7:0] value;
    integer updates=0;
    assign sda = sda_low ? 1'b0 : 1'bz;
    always #20 clk=~clk;
    board_top #(.RESET_HOLD_CYCLES(8)) dut (
        .sys_clk(clk), .key0_n(key0_n), .uart_tx(uart_tx),
        .led0(led0), .led1(led1), .iic_scl(scl), .iic_sda(sda)
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
    task greeting; begin
        receive_expected(8'h52); receive_expected(8'h56);
        receive_expected(8'h33); receive_expected(8'h32);
        receive_expected(8'h20); receive_expected(8'h52);
        receive_expected(8'h45); receive_expected(8'h41);
        receive_expected(8'h44); receive_expected(8'h59); receive_expected(10);
        expect_reg(8'h20,0);
    end endtask
    initial begin
        reset_board;
        expect_reg(8'h03,1);
        greeting;
        write_reg(8'h10,8'h79); write_reg(8'h11,8'h56);
        write_reg(8'h12,8'h34); write_reg(8'h13,8'h12);
        expect_reg(8'h20,0); // shadow writes must not cause CPU reply
        write_reg(8'h14,1);
        receive_expected(8'h79); receive_expected(8'h56);
        receive_expected(8'h34); receive_expected(8'h12);
        expect_reg(8'h20,0);
        if(led0!==1 || led1!==0) $fatal(1,"CPU parameter application failed");
        if(dut.u_soc.u_peripheral_bus.param_pending!==0) $fatal(1,"CPU did not acknowledge parameter");
        // Restart while mailbox contains an unread reply; reset clears stale data.
        write_reg(8'h14,1); wait_data;
        reset_board; greeting;
        if(led0!==0 || led1!==0) $fatal(1,"Reset did not clear application state");
        $display("PASS: actual RV32 firmware -> FIFO -> IIC, RK parameter -> CPU -> echo/GPIO, reset recovery");
        $finish;
    end
    initial begin #100000000; $fatal(1,"Board I2C test timeout"); end
endmodule
