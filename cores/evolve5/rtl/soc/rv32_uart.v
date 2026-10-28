`timescale 1ns/1ps
// 8 data bits, no parity, one stop bit. One TX frame + 4-byte RX FIFO.
// MMIO DATA writes wait for idle TX; reads wait for an available RX byte.
module rv32_uart #(
    parameter integer CLOCK_HZ = 50000000,
    parameter integer BAUD = 115200
) (
    input wire clk, rst,
    input wire valid, write,
    input wire [11:0] addr,
    input wire [31:0] wdata,
    input wire [3:0] wstrb,
    output reg ready,
    output reg [31:0] rdata,
    output reg error,
    input wire rx,
    output reg tx
);
    localparam integer INITIAL_DIV = (CLOCK_HZ + BAUD/2)/BAUD;
    reg [15:0] divisor;
    wire [31:0] byte_mask = {{8{wstrb[3]}},{8{wstrb[2]}},{8{wstrb[1]}},{8{wstrb[0]}}};
    wire [31:0] merged_div = ({16'b0,divisor} & ~byte_mask) | (wdata & byte_mask);
    reg tx_busy;
    reg [15:0] tx_div, tx_count;
    reg [9:0] tx_frame;
    reg [3:0] tx_bit;
    reg rx_meta /* synthesis syn_preserve=1 */;
    reg rx_sync /* synthesis syn_preserve=1 */;
    localparam RX_IDLE=0, RX_START=1, RX_DATA=2, RX_STOP=3, RX_RECOVER=4;
    reg [2:0] rx_state;
    reg [15:0] rx_div, rx_count;
    reg [2:0] rx_bit;
    reg [7:0] rx_shift, received;
    reg receive_pulse, frame_error_pulse;
    reg [7:0] fifo [0:3];
    reg [1:0] read_ptr, write_ptr;
    reg [2:0] fifo_count;
    reg overrun, frame_error;
    wire data_reg = addr[11:2] == 0;
    wire status_reg = addr[11:2] == 1;
    wire fire = valid && ready && !error;
    wire pop = fire && data_reg && !write;
    wire push = receive_pulse && (fifo_count < 4 || pop);

    always @* begin
        ready = valid; rdata = 0; error = 0;
        case (addr[11:2])
            10'h000: begin
                rdata = fifo_count != 0 ? {24'b0,fifo[read_ptr]} : 0;
                if (addr[1:0] != 0 || (write && !wstrb[0])) error = 1;
                else ready = valid && (write ? !tx_busy : fifo_count != 0);
            end
            10'h001: rdata = {27'b0,(rx_state != RX_IDLE),frame_error,overrun,(fifo_count != 0),!tx_busy};
            10'h002: begin
                rdata = {16'b0,divisor};
                if (write && (merged_div < 8 || merged_div > 65535)) error = 1;
            end
            10'h003: begin rdata = {29'b0,fifo_count}; error = write; end
            default: error = 1;
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            divisor <= INITIAL_DIV;
            tx <= 1; tx_busy <= 0; tx_div <= INITIAL_DIV;
            tx_count <= 0; tx_frame <= 10'h3ff; tx_bit <= 0;
        end else begin
            if (fire && write && addr[11:2] == 2) divisor <= merged_div[15:0];
            if (tx_busy) begin
                if (tx_count == 0) begin
                    if (tx_bit == 9) begin tx_busy <= 0; tx <= 1; end
                    else begin
                        tx_bit <= tx_bit + 1;
                        tx <= tx_frame[tx_bit + 1];
                        tx_count <= tx_div - 1;
                    end
                end else tx_count <= tx_count - 1;
            end else if (fire && data_reg && write) begin
                tx_frame <= {1'b1,wdata[7:0],1'b0};
                tx_div <= divisor; tx_count <= divisor - 1;
                tx_bit <= 0; tx_busy <= 1; tx <= 0;
            end
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            rx_meta <= 1; rx_sync <= 1; rx_state <= RX_IDLE;
            rx_div <= INITIAL_DIV; rx_count <= 0; rx_bit <= 0;
            rx_shift <= 0; received <= 0; receive_pulse <= 0; frame_error_pulse <= 0;
        end else begin
            rx_meta <= rx; rx_sync <= rx_meta;
            receive_pulse <= 0; frame_error_pulse <= 0;
            case (rx_state)
                RX_IDLE: if (!rx_sync) begin
                    rx_div <= divisor; rx_count <= (divisor >> 1) - 1; rx_state <= RX_START;
                end
                RX_START: begin
                    if (rx_count != 0) rx_count <= rx_count - 1;
                    else if (rx_sync) rx_state <= RX_IDLE; // reject a short low glitch
                    else begin rx_state <= RX_DATA; rx_bit <= 0; rx_count <= rx_div - 1; end
                end
                RX_DATA: begin
                    if (rx_count != 0) rx_count <= rx_count - 1;
                    else begin
                        rx_shift[rx_bit] <= rx_sync; rx_count <= rx_div - 1;
                        if (rx_bit == 7) rx_state <= RX_STOP;
                        else rx_bit <= rx_bit + 1;
                    end
                end
                RX_STOP: begin
                    if (rx_count != 0) rx_count <= rx_count - 1;
                    else if (rx_sync) begin
                        received <= rx_shift; receive_pulse <= 1; rx_state <= RX_IDLE;
                    end else begin frame_error_pulse <= 1; rx_state <= RX_RECOVER; end
                end
                RX_RECOVER: if (rx_sync) rx_state <= RX_IDLE;
                default: rx_state <= RX_IDLE;
            endcase
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            read_ptr <= 0; write_ptr <= 0; fifo_count <= 0;
            overrun <= 0; frame_error <= 0;
        end else begin
            if (fire && write && status_reg && wstrb[0]) begin
                if (wdata[2]) overrun <= 0;
                if (wdata[3]) frame_error <= 0;
            end
            // A newly observed error wins over a simultaneous software clear.
            if (receive_pulse && !push) overrun <= 1;
            if (frame_error_pulse) frame_error <= 1;
            if (push) begin fifo[write_ptr] <= received; write_ptr <= write_ptr + 1; end
            if (pop) read_ptr <= read_ptr + 1;
            case ({push,pop})
                2'b10: fifo_count <= fifo_count + 1;
                2'b01: fifo_count <= fifo_count - 1;
                default: fifo_count <= fifo_count;
            endcase
        end
    end
endmodule
