module PC (
    input clk,
    input rst_n,
    input load_pc_en,
    input [31:0]load_pc,

    input stall,
    input flush,
    input valid_in,
    
    output reg valid_out,
    output [31:0]pc
);
    reg [31:0]PC_counter;

    always @(posedge clk) begin
        if(!rst_n)
            PC_counter <= 32'b0;
        else begin
            if(stall)
                PC_counter <= PC_counter;
            else begin
                if(load_pc_en)
                    PC_counter <= load_pc;
                else
                    PC_counter <= PC_counter + 32'h4; 
            end 
        end
    end

    always @(posedge clk) begin
        if(!rst_n | flush)
            valid_out <= 0;
        else begin
            if(stall)
                valid_out <= valid_out;
            else
                valid_out <= valid_in;      // 必须非阻塞：写成 = 会和同拍读它的逻辑抢时序
        end
    end

    assign pc   = PC_counter;

endmodule
