`timescale 1ns/1ps
// Bounded instruction FIFO, one outstanding completion-handshake request.
// The pending request reserves a free slot. Redirect flushes entries and drains
// any old request without cancelling the external transaction.
module rv32_fetch #(
    parameter [31:0] RESET_PC=32'h00000000,
    parameter integer BP_ENABLE=1, BP_INDEX_BITS=5,
    parameter integer GSHARE_ENABLE=0, PHT_BITS=8, RAS_DEPTH=0, DEPTH=1, BYPASS=0, DUAL_ENABLE=0, WIDE_FETCH=0
)(
    input wire clk,rst,stop,redirect,
    input wire [31:0] redirect_pc,
    output wire req_valid,
    output wire [31:0] req_addr,
    input wire rsp_ready,
    input wire [31:0] rsp_data,
    input wire rsp_error,
    input wire rsp_second_valid,rsp_second_error,
    input wire [31:0] rsp_data_second,
    output wire [31:0] buf_second_next_pc,
    output wire buf_second_hit,buf_second_taken,buf_second_ras,
    output wire [PHT_BITS-1:0] buf_second_index,
    output wire buf_second_valid,buf_second_error,
    output wire [31:0] buf_second_pc,buf_second_insn,
    input wire buf_take_second,
    output wire buf_valid,
    output wire [31:0] buf_pc,buf_insn,
    output wire buf_error,
    output wire [31:0] buf_predicted_next_pc,
    output wire buf_prediction_hit,buf_prediction_taken,buf_prediction_ras,
    output wire [PHT_BITS-1:0] buf_prediction_index,
    input wire bp_update_valid,bp_update_conditional,bp_update_taken,
    input wire [31:0] bp_update_pc,bp_update_target,bp_update_insn,
    input wire [PHT_BITS-1:0] bp_update_index,
    input wire bp_flush,
    input wire buf_ready
);
    wire active,killed;
    wire [$clog2(DEPTH+1)-1:0] count;
    generate if(DUAL_ENABLE || WIDE_FETCH) begin: expanded
        rv32_fetch_dual #(.RESET_PC(RESET_PC),.BP_ENABLE(BP_ENABLE),.BP_INDEX_BITS(BP_INDEX_BITS),.GSHARE_ENABLE(GSHARE_ENABLE),
        .PHT_BITS(PHT_BITS),.RAS_DEPTH(RAS_DEPTH),.DEPTH(DEPTH),.BYPASS(BYPASS),.DUAL_ENABLE(DUAL_ENABLE),.WIDE_FETCH(WIDE_FETCH)) impl(
        .clk(clk),.rst(rst),.stop(stop),.redirect(redirect),.redirect_pc(redirect_pc),
        .req_valid(req_valid),.req_addr(req_addr),.rsp_ready(rsp_ready),.rsp_data(rsp_data),.rsp_error(rsp_error),
        .buf_valid(buf_valid),.buf_pc(buf_pc),.buf_insn(buf_insn),.buf_error(buf_error),.buf_ready(buf_ready),
        .buf_predicted_next_pc(buf_predicted_next_pc),.buf_prediction_hit(buf_prediction_hit),.buf_prediction_taken(buf_prediction_taken),
        .buf_prediction_ras(buf_prediction_ras),.buf_prediction_index(buf_prediction_index),
        .bp_update_valid(bp_update_valid),.bp_update_conditional(bp_update_conditional),.bp_update_taken(bp_update_taken),
        .bp_update_pc(bp_update_pc),.bp_update_target(bp_update_target),.bp_update_insn(bp_update_insn),.bp_update_index(bp_update_index),.bp_flush(bp_flush),
        .dbg_active(active),.dbg_killed(killed),.dbg_count(count),
        .rsp_second_valid(rsp_second_valid),.rsp_second_error(rsp_second_error),.rsp_data_second(rsp_data_second),
        .buf_second_valid(buf_second_valid),.buf_second_error(buf_second_error),.buf_second_pc(buf_second_pc),.buf_second_insn(buf_second_insn),
        .buf_second_next_pc(buf_second_next_pc),.buf_second_hit(buf_second_hit),.buf_second_taken(buf_second_taken),
        .buf_second_ras(buf_second_ras),.buf_second_index(buf_second_index),.buf_take_second(buf_take_second));
    end else begin: scalar
        rv32_fetch_scalar #(.RESET_PC(RESET_PC),.BP_ENABLE(BP_ENABLE),.BP_INDEX_BITS(BP_INDEX_BITS),.GSHARE_ENABLE(GSHARE_ENABLE),
        .PHT_BITS(PHT_BITS),.RAS_DEPTH(RAS_DEPTH),.DEPTH(DEPTH),.BYPASS(BYPASS)) impl(.clk(clk),.rst(rst),.stop(stop),.redirect(redirect),.redirect_pc(redirect_pc),
        .req_valid(req_valid),.req_addr(req_addr),.rsp_ready(rsp_ready),.rsp_data(rsp_data),.rsp_error(rsp_error),
        .buf_valid(buf_valid),.buf_pc(buf_pc),.buf_insn(buf_insn),.buf_error(buf_error),.buf_ready(buf_ready),
        .buf_predicted_next_pc(buf_predicted_next_pc),.buf_prediction_hit(buf_prediction_hit),.buf_prediction_taken(buf_prediction_taken),
        .buf_prediction_ras(buf_prediction_ras),.buf_prediction_index(buf_prediction_index),
        .bp_update_valid(bp_update_valid),.bp_update_conditional(bp_update_conditional),.bp_update_taken(bp_update_taken),
        .bp_update_pc(bp_update_pc),.bp_update_target(bp_update_target),.bp_update_insn(bp_update_insn),.bp_update_index(bp_update_index),.bp_flush(bp_flush),
        .dbg_active(active),.dbg_killed(killed),.dbg_count(count));
        assign buf_second_next_pc=0;assign buf_second_hit=0;assign buf_second_taken=0;assign buf_second_ras=0;assign buf_second_index=0;
        assign buf_second_valid=1'b0;assign buf_second_error=1'b0;
        assign buf_second_pc=32'b0;assign buf_second_insn=32'b0;
    end endgenerate
endmodule

`timescale 1ns/1ps
// Bounded instruction FIFO, one outstanding completion-handshake request.
// The pending request reserves a free slot. Redirect flushes entries and drains
// any old request without cancelling the external transaction.
module rv32_fetch_scalar #(
    parameter [31:0] RESET_PC=32'h00000000,
    parameter integer BP_ENABLE=1, BP_INDEX_BITS=5,
    parameter integer GSHARE_ENABLE=0, PHT_BITS=8, RAS_DEPTH=0, DEPTH=1, BYPASS=0
)(
    input wire clk,rst,stop,redirect,
    input wire [31:0] redirect_pc,
    output wire req_valid,
    output wire [31:0] req_addr,
    input wire rsp_ready,
    input wire [31:0] rsp_data,
    input wire rsp_error,
    output wire buf_valid,
    output wire [31:0] buf_pc,buf_insn,
    output wire buf_error,
    output wire [31:0] buf_predicted_next_pc,
    output wire buf_prediction_hit,buf_prediction_taken,buf_prediction_ras,
    output wire [PHT_BITS-1:0] buf_prediction_index,
    input wire bp_update_valid,bp_update_conditional,bp_update_taken,
    input wire [31:0] bp_update_pc,bp_update_target,bp_update_insn,
    input wire [PHT_BITS-1:0] bp_update_index,
    input wire bp_flush,
    output wire dbg_active,dbg_killed,
    output wire [$clog2(DEPTH+1)-1:0] dbg_count,
    input wire buf_ready
);
    localparam PTR_BITS=DEPTH>1?$clog2(DEPTH):1;
    reg [31:0] pc,saved_target;
    reg active,killed;
    reg [PTR_BITS-1:0] read_ptr,write_ptr;
    reg [$clog2(DEPTH+1)-1:0] count;
    reg [31:0] pcs[0:DEPTH-1],insns[0:DEPTH-1],next_pcs[0:DEPTH-1];
    reg [3:0] meta[0:DEPTH-1];
    reg [PHT_BITS-1:0] indices[0:DEPTH-1];
    wire prediction_hit,prediction_taken,prediction_ras;
    wire [31:0] predicted_next_pc;
    wire [PHT_BITS-1:0] prediction_index;
    rv32_predictor #(.ENABLE(BP_ENABLE),.INDEX_BITS(BP_INDEX_BITS),.GSHARE_ENABLE(GSHARE_ENABLE),.PHT_BITS(PHT_BITS),.RAS_DEPTH(RAS_DEPTH)) predictor(
        .clk(clk),.rst(rst),.query_pc(pc),.query_insn(rsp_data),.query_error(rsp_error),
        .hit(prediction_hit),.taken(prediction_taken),.next_pc(predicted_next_pc),.prediction_index(prediction_index),.ras_hit(prediction_ras),
        .update_valid(bp_update_valid),.update_conditional(bp_update_conditional),.update_taken(bp_update_taken),
        .update_pc(bp_update_pc),.update_target(bp_update_target),.update_insn(bp_update_insn),.update_index(bp_update_index),.context_flush(bp_flush)
    );
    wire stored=count!=0;
    wire pop=stored && buf_ready && !stop && !redirect;
    assign req_addr=pc;
    assign req_valid=!rst && (active || (!stop && !redirect && (count<DEPTH || pop)));
    wire response=req_valid && rsp_ready && !killed && !redirect && !stop;
    wire direct=BYPASS && !stored && response;
    wire push=response && !(direct && buf_ready);
    assign buf_valid=stored || direct;
    assign buf_pc=stored || !BYPASS ? pcs[read_ptr] : pc;
    assign buf_insn=stored || !BYPASS ? insns[read_ptr] : rsp_data;
    assign buf_predicted_next_pc=stored || !BYPASS ? next_pcs[read_ptr] : predicted_next_pc;
    assign {buf_error,buf_prediction_hit,buf_prediction_taken,buf_prediction_ras}=stored || !BYPASS ? meta[read_ptr] : {rsp_error,prediction_hit,prediction_taken,prediction_ras};
    assign buf_prediction_index=stored || !BYPASS ? indices[read_ptr] : prediction_index;
    integer k;
    always @(posedge clk) begin
        if(rst) begin
            pc<=RESET_PC; saved_target<=RESET_PC; active<=0; killed<=0;
            count<=0; read_ptr<=0; write_ptr<=0;
            for(k=0;k<DEPTH;k=k+1) begin pcs[k]<=0;insns[k]<=0;next_pcs[k]<=RESET_PC+4;meta[k]<=0;indices[k]<=0;end
        end else begin
            if(stop || redirect) begin count<=0;read_ptr<=0;write_ptr<=0;end
            else begin
                case({push,pop}) 2'b10:count<=count+1'b1; 2'b01:count<=count-1'b1; default:begin end endcase
                if(pop) read_ptr<=(read_ptr==DEPTH-1)?0:read_ptr+1'b1;
                if(push) begin
                    pcs[write_ptr]<=pc;insns[write_ptr]<=rsp_data;next_pcs[write_ptr]<=predicted_next_pc;
                    meta[write_ptr]<={rsp_error,prediction_hit,prediction_taken,prediction_ras};indices[write_ptr]<=prediction_index;
                    write_ptr<=(write_ptr==DEPTH-1)?0:write_ptr+1'b1;
                end
            end
            if(req_valid && rsp_ready) begin
                active<=0; killed<=0;
                pc<=killed?saved_target:predicted_next_pc;
            end else if(req_valid) active<=1;
            if(stop && active && !rsp_ready && !killed) begin killed<=1;saved_target<=pc;end
            if(redirect) begin
                if(active && !rsp_ready) begin killed<=1;saved_target<=redirect_pc;end
                else begin pc<=redirect_pc;killed<=0;end
            end
        end
    end
    assign dbg_active=active;assign dbg_killed=killed;assign dbg_count=count;
endmodule

`timescale 1ns/1ps
// Bounded instruction FIFO, one outstanding completion-handshake request.
// The pending request reserves a free slot. Redirect flushes entries and drains
// any old request without cancelling the external transaction.
module rv32_fetch_dual #(
    parameter [31:0] RESET_PC=32'h00000000,
    parameter integer BP_ENABLE=1, BP_INDEX_BITS=5,
    parameter integer GSHARE_ENABLE=0, PHT_BITS=8, RAS_DEPTH=0, DEPTH=1, BYPASS=0, DUAL_ENABLE=0, WIDE_FETCH=0
)(
    input wire clk,rst,stop,redirect,
    input wire [31:0] redirect_pc,
    output wire req_valid,
    output wire [31:0] req_addr,
    input wire rsp_ready,
    input wire [31:0] rsp_data,
    input wire rsp_error,
    input wire rsp_second_valid,rsp_second_error,
    input wire [31:0] rsp_data_second,
    output wire [31:0] buf_second_next_pc,
    output wire buf_second_hit,buf_second_taken,buf_second_ras,
    output wire [PHT_BITS-1:0] buf_second_index,
    output wire buf_second_valid,buf_second_error,
    output wire [31:0] buf_second_pc,buf_second_insn,
    input wire buf_take_second,
    output wire buf_valid,
    output wire [31:0] buf_pc,buf_insn,
    output wire buf_error,
    output wire [31:0] buf_predicted_next_pc,
    output wire buf_prediction_hit,buf_prediction_taken,buf_prediction_ras,
    output wire [PHT_BITS-1:0] buf_prediction_index,
    input wire bp_update_valid,bp_update_conditional,bp_update_taken,
    input wire [31:0] bp_update_pc,bp_update_target,bp_update_insn,
    input wire [PHT_BITS-1:0] bp_update_index,
    input wire bp_flush,
    output wire dbg_active,dbg_killed,
    output wire [$clog2(DEPTH+1)-1:0] dbg_count,
    input wire buf_ready
);
    // DEPTH must be at least two. Reserve the maximum response width before
    // issuing; no combinational dependence on the consumer's pair decision.
    localparam ITEM_BITS=100+PHT_BITS, RESERVE=WIDE_FETCH?2:1;
    reg [31:0] pc,saved_target;
    reg active,killed;
    reg [$clog2(DEPTH+1)-1:0] count,next_count;
    reg [ITEM_BITS-1:0] items[0:DEPTH-1],next_items[0:DEPTH-1];
    wire hit0,taken0,ras0,hit1,taken1,ras1;
    wire [31:0] next0,next1;
    wire [PHT_BITS-1:0] index0,index1;
    wire [31:0] second_pc=pc+4;
    rv32_predictor #(.ENABLE(BP_ENABLE),.INDEX_BITS(BP_INDEX_BITS),.GSHARE_ENABLE(GSHARE_ENABLE),.PHT_BITS(PHT_BITS),.RAS_DEPTH(RAS_DEPTH)) predictor(
        .clk(clk),.rst(rst),.query_pc(pc),.query_insn(rsp_data),.query_error(rsp_error),
        .hit(hit0),.taken(taken0),.next_pc(next0),.prediction_index(index0),.ras_hit(ras0),
        .update_valid(bp_update_valid),.update_conditional(bp_update_conditional),.update_taken(bp_update_taken),
        .update_pc(bp_update_pc),.update_target(bp_update_target),.update_insn(bp_update_insn),.update_index(bp_update_index),.context_flush(bp_flush));
    generate if(WIDE_FETCH) begin: query_second
        // Identical retirement training, independent query address. GHR/RAS
        // remain committed state; both prediction indices travel with the words.
        rv32_predictor #(.ENABLE(BP_ENABLE),.INDEX_BITS(BP_INDEX_BITS),.GSHARE_ENABLE(GSHARE_ENABLE),.PHT_BITS(PHT_BITS),.RAS_DEPTH(RAS_DEPTH)) predictor(
            .clk(clk),.rst(rst),.query_pc(second_pc),.query_insn(rsp_data_second),.query_error(rsp_second_error),
            .hit(hit1),.taken(taken1),.next_pc(next1),.prediction_index(index1),.ras_hit(ras1),
            .update_valid(bp_update_valid),.update_conditional(bp_update_conditional),.update_taken(bp_update_taken),
            .update_pc(bp_update_pc),.update_target(bp_update_target),.update_insn(bp_update_insn),.update_index(bp_update_index),.context_flush(bp_flush));
    end else begin: query_single
        assign hit1=0;assign taken1=0;assign ras1=0;assign next1=second_pc+4;assign index1=0;
    end endgenerate
    assign req_addr=pc;
    assign req_valid=!rst && (active || (!stop && !redirect && count<=DEPTH-RESERVE));
    wire second_ok=WIDE_FETCH && rsp_second_valid && !rsp_error && next0==second_pc;
    wire live=req_valid && rsp_ready && !killed && !stop && !redirect;
    wire [ITEM_BITS-1:0] response0={pc,rsp_data,next0,rsp_error,hit0,taken0,ras0,index0};
    wire [ITEM_BITS-1:0] response1={second_pc,rsp_data_second,next1,rsp_second_error,hit1,taken1,ras1,index1};
    wire [ITEM_BITS-1:0] head0=count!=0?items[0]:response0;
    wire [ITEM_BITS-1:0] head1=count>1?items[1]:count==1?response0:response1;
    assign buf_valid=count!=0 || (BYPASS && live);
    assign buf_second_valid=count>1 || (BYPASS && live && (count==1 || second_ok));
    assign {buf_pc,buf_insn,buf_predicted_next_pc,buf_error,buf_prediction_hit,buf_prediction_taken,buf_prediction_ras,buf_prediction_index}=head0;
    wire [31:0] unused_next;
    wire [2:0] unused_meta;
    wire [PHT_BITS-1:0] unused_index;
    assign {buf_second_pc,buf_second_insn,buf_second_next_pc,buf_second_error,buf_second_hit,buf_second_taken,buf_second_ras,buf_second_index}=head1;
    integer consumed,stored_pop,direct_pop,remaining,incoming,k;
    always @* begin
        incoming=live?(second_ok?2:1):0;
        consumed=!stop && !redirect && buf_valid && buf_ready ? ((DUAL_ENABLE && buf_take_second && buf_second_valid)?2:1):0;
        stored_pop=consumed>count?count:consumed;
        direct_pop=consumed-stored_pop;
        remaining=count-stored_pop;
        next_count=count+incoming-consumed;
        for(k=0;k<DEPTH;k=k+1) begin
            next_items[k]=0;
            if(k<remaining) next_items[k]=items[k+stored_pop];
            if(incoming>direct_pop && k==remaining) next_items[k]=direct_pop==0?response0:response1;
            if(incoming-direct_pop==2 && k==remaining+1) next_items[k]=response1;
        end
    end
    integer q;
    always @(posedge clk) begin
        if(rst) begin
            pc<=RESET_PC;saved_target<=RESET_PC;active<=0;killed<=0;count<=0;
            for(q=0;q<DEPTH;q=q+1) items[q]<=0;
        end else begin
            if(stop || redirect) count<=0;
            else begin
                count<=next_count;
                for(q=0;q<DEPTH;q=q+1) items[q]<=next_items[q];
            end
            if(req_valid && rsp_ready) begin
                active<=0;killed<=0;
                pc<=killed?saved_target:(second_ok?next1:next0);
            end else if(req_valid) active<=1;
            if(stop && active && !rsp_ready && !killed) begin killed<=1;saved_target<=pc;end
            if(redirect) begin
                if(active && !rsp_ready) begin killed<=1;saved_target<=redirect_pc;end
                else begin pc<=redirect_pc;killed<=0;end
            end
        end
    end
    assign dbg_active=active;assign dbg_killed=killed;assign dbg_count=count;
endmodule
