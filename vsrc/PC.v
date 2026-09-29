module PC (
    input clk,
    input rst_n,
    input jump_en,
    input en,               // 用于控制是否递增或跳转，拉低可以产生空泡
    input [31:0]jump_addr,
    output [31:0]pc
);
    reg [31:0]PC_counter;

    always @(posedge clk) begin
        if(!rst_n)
            PC_counter <= 32'b0;
        else begin
            if(!en)
                PC_counter <= PC_counter;
            else begin
                if(jump_en)
                    PC_counter <= jump_addr;
                else
                    PC_counter <= PC_counter + 32'h4; 
            end 
        end
    end

    assign pc = PC_counter;
endmodule
