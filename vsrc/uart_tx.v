module uart_tx #(
     parameter integer CLK_FREQ  = 25_000_000,
     parameter integer BAUD_RATE = 115200
)(
    input clk,
    input rst_n,
    input tx_start,
    input [7:0] tx_data,

    output reg tx,
    output reg busy
);
//波特率计算
localparam integer CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;
reg [31:0] baud_cnt;

reg [2:0] bit_idx;// 数据位计数器
reg [1:0] state;               
reg [7:0] data_buf;// 保存本次发送的数据

localparam [1:0]    IDLE = 2'd0,
                    START = 2'd1,
                    DATA = 2'd2,
                    STOP = 2'd3;

     


always @(posedge clk) begin
    if(!rst_n)begin
        state <= IDLE;
        baud_cnt    <= 0;
        bit_idx     <= 0;
        data_buf    <= 0;
        tx          <= 1'b1;
        busy        <= 1'b0;
end
else begin
    //串口发送状态机
    case(state)

    IDLE: begin
                tx       <= 1'b1;
                busy     <= 1'b0;
                baud_cnt <= 0;
                bit_idx  <= 0;        

                if (tx_start) 
                begin
                    data_buf <= tx_data;
                    busy     <= 1'b1;
                    state    <= START;
                end
            end        
    START: begin
                tx <= 1'b0;

                if (baud_cnt == CLKS_PER_BIT - 1) begin
                    baud_cnt <= 0;
                    bit_idx  <= 0;
                    state    <= DATA;
                end
                else begin
                    baud_cnt <= baud_cnt + 1;
                end
            end

    DATA: begin
                tx <= data_buf[bit_idx];

                if (baud_cnt == CLKS_PER_BIT - 1) begin //???
                    baud_cnt <= 0;

                if (bit_idx == 3'd7) begin
                    state <= STOP;
                    bit_idx <= 0;
                end
                else begin
                    bit_idx <= bit_idx + 1;
                end
                end
                else begin
                    baud_cnt <= baud_cnt + 1;
                end
            
    end
    STOP: begin
                tx <= 1'd1;

                if (baud_cnt == CLKS_PER_BIT - 1) begin
                    baud_cnt <= 0;
                    state    <= IDLE;
                    // Keep busy high until IDLE executes on the next edge.
                    // The registered TX output starts STOP one edge after entry.
                end
                else begin
                    baud_cnt <= baud_cnt + 1;
                end
            end

    default: begin
                state    <= IDLE;
                baud_cnt <= 0;
                bit_idx  <= 0;
                tx       <= 1'b1;
                busy     <= 1'b0;
            end
    endcase
end
end
endmodule
