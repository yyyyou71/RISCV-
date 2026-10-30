`timescale 1ns/1ps
module TB_ddr_unknown_write;
    ddr3 memory(.ref_clk(1'b0),.resetn(1'b0));
    reg [127:0] value;
    initial begin
        #1;
        // Masked X bytes are legal; the enabled byte is fully known.
        memory.store_word(28'd0,{120'bx,8'h5a},16'h0001);
        value=memory.load_word(28'd0);
        if(value[7:0]!==8'h5a)$fatal(1,"masked write corrupted known byte");
        $display("PASS masked unknown bytes ignored; expecting enabled-X rejection next");
        memory.store_word(28'd8,{120'd0,8'bx},16'h0001);
        $fatal(1,"Enabled unknown byte was accepted");
    end
endmodule
