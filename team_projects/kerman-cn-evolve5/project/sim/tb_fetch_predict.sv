`timescale 1ns/1ps
module tb_fetch_predict;
    reg clk=0; always #5 clk=~clk;
    reg rst=1,stop=0,redirect=0,rsp_ready=0,rsp_error=0,buf_ready=0;
    reg [31:0] redirect_pc=0,rsp_data=32'h0000006f;
    reg uv=0,uc=0,ut=1; reg [31:0] up=0,target=32'h40;
    wire req_valid,buf_valid,buf_error,ph,pt;
    wire [31:0] req_addr,buf_pc,buf_insn,pnpc;
    rv32_fetch #(.BP_INDEX_BITS(2)) dut(.clk(clk),.rst(rst),.stop(stop),.redirect(redirect),.redirect_pc(redirect_pc),
      .req_valid(req_valid),.req_addr(req_addr),.rsp_ready(rsp_ready),.rsp_data(rsp_data),.rsp_error(rsp_error),
      .buf_valid(buf_valid),.buf_pc(buf_pc),.buf_insn(buf_insn),.buf_error(buf_error),.buf_ready(buf_ready),
      .buf_predicted_next_pc(pnpc),.buf_prediction_hit(ph),.buf_prediction_taken(pt),
      .bp_update_valid(uv),.bp_update_conditional(uc),.bp_update_taken(ut),.bp_update_pc(up),.bp_update_target(target));
    reg waiting=0; reg [31:0] held_addr;
    always @(posedge clk) begin
        if(rst) waiting=0;
        else begin
            if(waiting && (!req_valid || req_addr!==held_addr)) $fatal(1,"Fetch changed outstanding request");
            waiting=req_valid&&!rsp_ready; held_addr=req_addr;
        end
    end
    initial begin
        repeat(3) @(posedge clk); @(negedge clk); rst=0; uv=1;
        @(posedge clk); #1;
        @(negedge clk); target=32'h80;
        @(posedge clk); #1;
        @(negedge clk); uv=0; rsp_ready=1;
        @(posedge clk); #1;
        if(!buf_valid || buf_pc!==0 || pnpc!==32'h80 || !ph || !pt || req_addr!==32'h80) $fatal(1,"Prediction not paired with response-time table state");
        @(negedge clk); rsp_ready=0;
        repeat(3) begin @(posedge clk); #1; if(!buf_valid || pnpc!==32'h80 || req_valid) $fatal(1,"Stalled ID lost prediction metadata"); end
        @(negedge clk); buf_ready=1;
        @(posedge clk); #1;
        @(negedge clk); redirect=1; redirect_pc=32'h100;
        @(posedge clk); #1;
        @(negedge clk); redirect_pc=32'h120;
        @(posedge clk); #1;
        @(negedge clk); redirect=0; rsp_ready=1;
        @(posedge clk); #1;
        if(buf_valid || req_addr!==32'h120) $fatal(1,"Killed predicted response survived or older redirect won");
        @(negedge clk); rsp_error=1; buf_ready=0;
        @(posedge clk); #1;
        if(!buf_valid || !buf_error || ph || pt || pnpc!==32'h124) $fatal(1,"Faulting fetch incorrectly predicted a target");
        @(negedge clk); rsp_ready=0; rsp_error=0; buf_ready=1;
        @(posedge clk); #1;
        @(negedge clk); stop=1;
        @(posedge clk); #1;
        @(negedge clk); rsp_ready=1;
        @(posedge clk); #1;
        if(buf_valid || req_valid) $fatal(1,"Quiesced response issued an instruction");
        @(negedge clk); rsp_ready=0; redirect=1; redirect_pc=32'h200;
        @(posedge clk); #1;
        @(negedge clk); redirect=0; stop=0;
        #1; if(!req_valid || req_addr!==32'h200) $fatal(1,"Resume after stop used speculative PC");
        $display("FETCH_PREDICT_PASS response_metadata hold redirect_supersession fault stop_resume"); $finish;
    end
    initial begin #10000; $fatal(1,"Fetch test timeout"); end
endmodule
