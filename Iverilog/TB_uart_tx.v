`timescale 1ns/1ps

module TB_uart_tx;
    localparam integer CLKS_PER_BIT = 4;
    reg clk = 0;
    reg rst_n = 0;
    reg tx_start = 0;
    reg [7:0] tx_data = 0;
    wire tx;
    wire busy;
    integer early_busy = 0;

    always #5 clk = ~clk;

    uart_tx #(.CLK_FREQ(40), .BAUD_RATE(10)) dut (
        .clk(clk), .rst_n(rst_n), .tx_start(tx_start),
        .tx_data(tx_data), .tx(tx), .busy(busy)
    );

    // Check every clock interval of all ten bits, not only their centers.
    task receive_frame;
        input [7:0] expected;
        reg [9:0] frame;
        integer b;
        integer c;
        begin
            frame = {1'b1, expected, 1'b0};
            @(negedge tx);
            #1;
            for (b = 0; b < 10; b = b + 1) begin
                for (c = 0; c < CLKS_PER_BIT; c = c + 1) begin
                    if (tx !== frame[b])
                        $fatal(1, "TX mismatch: byte=%h bit=%0d cycle=%0d", expected, b, c);
                    if (!busy) begin
                        if (b != 9)
                            $fatal(1, "busy cleared before stop bit");
                        early_busy = early_busy + 1;
                    end
                    #10;
                end
            end
            if (tx !== 1'b1 || busy !== 1'b0)
                $fatal(1, "Transmitter did not return to idle");
            $display("FRAME PASS: %h", expected);
        end
    endtask

    task send_frame;
        input [7:0] value;
        input inject_busy_write;
        begin
            fork
                receive_frame(value);
                begin
                    @(negedge clk);
                    tx_data = value;
                    tx_start = 1;
                    @(negedge clk);
                    tx_start = 0;
                    // Changing input must not change the buffered frame.
                    tx_data = ~value;
                    if (inject_busy_write) begin
                        repeat (5) @(negedge clk);
                        tx_start = 1;
                        @(negedge clk);
                        tx_start = 0;
                    end
                end
            join
        end
    endtask

    initial begin
        $dumpfile("TB_uart_tx.vcd");
        $dumpvars(0, TB_uart_tx);
        repeat (3) @(negedge clk);
        if (tx !== 1 || busy !== 0) $fatal(1, "Reset failed");
        rst_n = 1;
        send_frame(8'h41, 1);
        send_frame(8'h00, 0);
        send_frame(8'hff, 0);
        send_frame(8'h55, 0);
        repeat (12 * CLKS_PER_BIT) begin
            @(negedge clk);
            if (tx !== 1 || busy !== 0) $fatal(1, "Unexpected extra frame");
        end
        $display("DATA PASS: reset, 8N1 timing, input latch, busy-write rejection, repeated frames");
        if (early_busy != 0)
            $fatal(1, "BUSY TIMING FAIL: busy was low during %0d final stop-bit clock intervals", early_busy);
        $display("PASS");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "Simulation timeout");
    end
endmodule
