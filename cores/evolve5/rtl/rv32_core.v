`timescale 1ns/1ps
`include "rv32_defs.vh"
// Optional restricted dual-issue, in-order RV32IM core: IF / ID / EX / MEM / WB.
// Bus contract: valid + ready completes exactly ONE transaction at a rising
// edge. The slave returns read data/error with ready. The master holds payload
// stable while waiting. There are no posted stores or combinational RAM claims.
// Machine-only traps: synchronous exceptions commit at WB; timer interrupts
// drain the pipeline before entering the handler. CSR instructions serialize.
// No lower privilege modes, PMP, MMU, or external interrupt controller.
module rv32_core #(
    parameter [31:0] RESET_PC = 32'h00000000,
    parameter [31:0] RESET_MTVEC = 32'h00000000,
    parameter integer M_ENABLE=0, DIV_ENABLE=0,
    parameter integer BP_ENABLE=1,
    parameter integer BP_INDEX_BITS=5,
    parameter integer GSHARE_ENABLE=0, PHT_BITS=8, RAS_DEPTH=0, FETCH_DEPTH=1, FETCH_BYPASS=0, LOAD_FORWARD=0,
    parameter integer DUAL_ENABLE=0, WIDE_FETCH=0, PAIR_BRANCH=0, PAIR_MEMORY=0, PAIR_JALR=0, FAST_MUL=0, FAST_STORE=0, PAIR_MUL=0
) (
    input wire clk, rst,
    input wire irq_timer,
    output wire interrupt_taken,
    output wire imem_valid,
    output wire [31:0] imem_addr,
    input wire imem_ready,
    input wire [31:0] imem_rdata,
    input wire imem_error,
    input wire imem_second_valid,imem_second_error,
    input wire [31:0] imem_rdata_second,
    output wire dmem_valid, dmem_write,
    output wire [31:0] dmem_addr, dmem_wdata,
    output wire [3:0] dmem_wstrb,
    input wire dmem_ready,
    input wire [31:0] dmem_rdata,
    input wire dmem_error,
    output reg halted,
    output reg [31:0] trap_pc, trap_cause, trap_tval,
    output wire retire_valid, retire_trap, retire_rd_we,
    output wire [31:0] retire_pc, retire_insn, retire_next_pc,
    output wire [4:0] retire_rd,
    output wire [31:0] retire_rd_data,
    output wire [31:0] retire_mem_addr, retire_mem_wdata, retire_mem_rdata,
    output wire [3:0] retire_mem_wmask, retire_mem_rmask,
    output wire [31:0] retire_cause, retire_tval,
    output wire [31:0] retire2_mem_addr,retire2_mem_wdata,retire2_mem_rdata,
    output wire [3:0] retire2_mem_wmask,retire2_mem_rmask,
    output wire retire2_valid,retire2_rd_we,
    output wire [31:0] retire2_pc,retire2_insn,retire2_next_pc,retire2_rd_data,
    output wire [4:0] retire2_rd,
    output reg [63:0] cycles, instret,
    output reg [63:0] load_stall_cycles, data_wait_cycles,
    output reg [63:0] fetch_wait_cycles, redirect_count
);
    // ID: the fetch buffer is the IF/ID pipeline register.
    wire id_valid, id_fetch_error, id_ready;
    wire [31:0] id_pc, id_insn;
    wire id2_valid,id2_fetch_error,issue_pair;
    wire [31:0] id2_pc,id2_insn,id2_imm,id2_r1,id2_r2;
    wire [4:0] id2_rs1,id2_rs2,id2_rd;
    wire id2_use1,id2_use2,id2_we,id2_pc_a,id2_imm_b,id2_illegal,id2_branch,id2_jal,id2_jalr,id2_load,id2_store;
    wire [31:0] id2_next_pc;
    wire id2_hit,id2_taken,id2_ras;
    wire [PHT_BITS-1:0] id2_index;
    wire [3:0] id2_alu;
    reg [31:0] issue_pairs,retired_pairs;
    wire [31:0] id_predicted_next_pc;
    wire id_prediction_hit,id_prediction_taken,id_prediction_ras;
    wire [PHT_BITS-1:0] id_prediction_index;
    wire bp_update_valid;
    wire bp_update_conditional,bp_update_taken;
    wire [31:0] bp_update_pc,bp_update_target;
    wire [31:0] bp_update_insn;
    wire [PHT_BITS-1:0] bp_update_index;
    wire [4:0] id_rs1, id_rs2, id_rd;
    wire id_use1, id_use2, id_we, id_pc_a, id_imm_b;
    wire id_load, id_store, id_branch, id_jal, id_jalr;
    wire id_illegal, id_ecall, id_ebreak;
    wire [31:0] id_imm, id_r1, id_r2;
    wire [3:0] id_alu;
    wire [2:0] id_f3;
    wire redirect;
    wire [31:0] redirect_pc;
    wire halting,secondary_exception_pending;
    wire id_csr = id_insn[6:0]==7'h73 && (id_f3==1 || id_f3==2 || id_f3==3 || id_f3==5 || id_f3==6 || id_f3==7);
    wire id_system = id_csr || id_insn==32'h30200073 || id_insn==32'h10500073;
    wire irq_enabled, irq_hold, irq_boundary;
    reg irq_draining;
    reg [31:0] arch_next_pc;
    wire [31:0] csr_read_data, csr_mtvec, csr_mepc;
    wire csr_known, csr_readonly;
    wire [31:0] count_inhibit;
    wire returning;
    wire csr_commit;
    wire [31:0] trap_target;
    rv32_fetch #(.RESET_PC(RESET_PC),.BP_ENABLE(BP_ENABLE),.BP_INDEX_BITS(BP_INDEX_BITS),.GSHARE_ENABLE(GSHARE_ENABLE),.PHT_BITS(PHT_BITS),.RAS_DEPTH(RAS_DEPTH),.DEPTH(FETCH_DEPTH),.BYPASS(FETCH_BYPASS),.DUAL_ENABLE(DUAL_ENABLE),.WIDE_FETCH(WIDE_FETCH)) fetch (
        .clk(clk), .rst(rst), .stop(halting || returning || irq_hold || secondary_exception_pending),
        .redirect(redirect), .redirect_pc(redirect_pc),
        .req_valid(imem_valid), .req_addr(imem_addr),
        .rsp_ready(imem_ready), .rsp_data(imem_rdata), .rsp_error(imem_error),
        .rsp_second_valid(imem_second_valid),.rsp_second_error(imem_second_error),.rsp_data_second(imem_rdata_second),
        .buf_second_next_pc(id2_next_pc),.buf_second_hit(id2_hit),.buf_second_taken(id2_taken),.buf_second_ras(id2_ras),.buf_second_index(id2_index),.buf_second_valid(id2_valid),.buf_second_pc(id2_pc),.buf_second_insn(id2_insn),.buf_second_error(id2_fetch_error),.buf_take_second(issue_pair && id_ready),
        .buf_valid(id_valid), .buf_pc(id_pc), .buf_insn(id_insn),
        .buf_error(id_fetch_error), .buf_ready(id_ready),
        .buf_predicted_next_pc(id_predicted_next_pc),.buf_prediction_hit(id_prediction_hit),.buf_prediction_taken(id_prediction_taken),.buf_prediction_ras(id_prediction_ras),.buf_prediction_index(id_prediction_index),
        .bp_update_valid(bp_update_valid),.bp_update_conditional(bp_update_conditional),.bp_update_taken(bp_update_taken),
        .bp_update_pc(bp_update_pc),.bp_update_target(bp_update_target),.bp_update_insn(bp_update_insn),.bp_update_index(bp_update_index),.bp_flush(halting || returning || irq_boundary)
    );
    rv32_decode #(.M_ENABLE(M_ENABLE),.DIV_ENABLE(DIV_ENABLE)) decode (
        .insn(id_insn), .rs1(id_rs1), .rs2(id_rs2), .rd(id_rd),
        .use_rs1(id_use1), .use_rs2(id_use2), .rd_write(id_we),
        .imm(id_imm), .alu_op(id_alu), .a_is_pc(id_pc_a), .b_is_imm(id_imm_b),
        .is_load(id_load), .is_store(id_store), .is_branch(id_branch),
        .is_jal(id_jal), .is_jalr(id_jalr), .funct3(id_f3),
        .illegal(id_illegal), .ecall(id_ecall), .ebreak(id_ebreak)
    );
    rv32_decode #(.M_ENABLE(M_ENABLE),.DIV_ENABLE(DIV_ENABLE)) decode_second (
        .insn(id2_insn),.rs1(id2_rs1),.rs2(id2_rs2),.rd(id2_rd),
        .use_rs1(id2_use1),.use_rs2(id2_use2),.rd_write(id2_we),.imm(id2_imm),.alu_op(id2_alu),
        .a_is_pc(id2_pc_a),.b_is_imm(id2_imm_b),.is_load(id2_load),.is_store(id2_store),.is_branch(id2_branch),.is_jal(id2_jal),.is_jalr(id2_jalr),.funct3(),
        .illegal(id2_illegal),.ecall(),.ebreak());
    wire primary_pair_type=id_insn[6:0]==7'h13 || id_insn[6:0]==7'h33 || id_insn[6:0]==7'h37 ||
                           id_insn[6:0]==7'h17 || id_insn[6:0]==7'h03 || id_insn[6:0]==7'h23;
    wire id_multiply=id_insn[6:0]==7'h33 && id_insn[31:25]==1;
    wire id2_multiply=id2_insn[6:0]==7'h33 && id2_insn[31:25]==1;
    wire secondary_pair_type=id2_insn[6:0]==7'h13 || (id2_insn[6:0]==7'h33 && (!id2_multiply || (PAIR_MUL && !id2_insn[14] && !id_multiply))) || id2_insn[6:0]==7'h37 || id2_insn[6:0]==7'h17 || (PAIR_BRANCH && (id2_branch || id2_jal) && id2_imm[1:0]==0) || (PAIR_JALR && id2_jalr) || (PAIR_MEMORY && (id2_load || id2_store) && !id_load && !id_store);
    wire pair_raw=id_we && id_rd!=0 && ((id2_use1 && id2_rs1==id_rd) || (id2_use2 && id2_rs2==id_rd));
    wire pair_waw=id_we && id2_we && id_rd!=0 && id_rd==id2_rd;
    assign issue_pair=DUAL_ENABLE && id_valid && id2_valid && !id_fetch_error && !id2_fetch_error && !id_illegal && !id2_illegal &&
                      primary_pair_type && secondary_pair_type && id2_pc==id_pc+4 && id_predicted_next_pc==id2_pc && !pair_raw && !pair_waw;
    rv32_regfile #(.DUAL_ENABLE(DUAL_ENABLE)) regfile (
        .clk(clk), .rst(rst), .rs1(id_rs1), .rs2(id_rs2),
        .rdata1(id_r1), .rdata2(id_r2),
        .we(retire_rd_we), .rd(retire_rd), .wdata(retire_rd_data),
        .rs3(id2_rs1),.rs4(id2_rs2),.rdata3(id2_r1),.rdata4(id2_r2),
        .we2(retire2_rd_we),.rd2(retire2_rd),.wdata2(retire2_rd_data)
    );

    // EX: ID/EX pipeline register and forwarded operands.
    reg x_valid, x_use1, x_use2, x_we, x_pc_a, x_imm_b;
    reg x_load, x_store, x_branch, x_jal, x_jalr, x_trap;
    reg [31:0] x_pc, x_insn, x_r1, x_r2, x_imm, x_cause, x_tval;
    reg [4:0] x_rs1, x_rs2, x_rd;
    reg [3:0] x_alu;
    reg [2:0] x_f3;
    reg [31:0] x_predicted_next_pc;
    reg x_prediction_hit,x_prediction_taken,x_prediction_ras;
    reg [PHT_BITS-1:0] x_prediction_index,m_prediction_index,w_prediction_index;
    reg m_prediction_ras,w_prediction_ras;
    reg [31:0] operand1, operand2;
    reg [31:0] load_value;
    reg x2_valid,x2_use1,x2_use2,x2_we,x2_pc_a,x2_imm_b;
    reg [31:0] x2_pc,x2_insn,x2_r1,x2_r2,x2_imm;
    reg [4:0] x2_rs1,x2_rs2,x2_rd;
    reg [3:0] x2_alu;
    reg [31:0] operand21,operand22;
    reg m2_valid,m2_we,w2_valid,w2_we;
    reg [31:0] m2_pc,m2_insn,m2_value,w2_pc,w2_insn,w2_value;
    reg [4:0] m2_rd,w2_rd;
    reg [31:0] x2_predicted,m2_next_pc,w2_next_pc;
    reg m2_load,m2_store,m2_trap,w2_trap;
    reg [31:0] m2_addr,m2_wdata,m2_cause,m2_tval,w2_addr,w2_wdata,w2_rdata,w2_cause,w2_tval;
    reg [3:0] m2_wmask,m2_rmask,w2_wmask,w2_rmask;
    reg [2:0] m2_f3;
    wire x2_load=x2_insn[6:0]==7'h03;
    wire x2_store=x2_insn[6:0]==7'h23;
    wire x2_jalr=x2_insn[6:0]==7'h67;
    wire [31:0] branch_target2=x2_jalr ? ((operand21+x2_imm)&32'hfffffffe) : x2_pc+x2_imm;
    reg x2_hit,x2_taken_pred,x2_ras,m2_hit,m2_pred_taken,m2_taken,m2_wrong,w2_hit,w2_pred_taken,w2_taken,w2_wrong;
    reg [PHT_BITS-1:0] x2_index,m2_index,w2_index;
    reg m2_ras,w2_ras;
    wire x2_branch=x2_insn[6:0]==7'h63;
    wire x2_jal=x2_insn[6:0]==7'h6f;
    reg branch2_condition;
    always @* begin
        case(x2_insn[14:12])
            0:branch2_condition=operand21==operand22;
            1:branch2_condition=operand21!=operand22;
            4:branch2_condition=$signed(operand21)<$signed(operand22);
            5:branch2_condition=$signed(operand21)>=$signed(operand22);
            6:branch2_condition=operand21<operand22;
            7:branch2_condition=operand21>=operand22;
            default:branch2_condition=0;
        endcase
    end
    wire x2_taking=x2_valid && (x2_jal || x2_jalr || (x2_branch && branch2_condition));
    wire [31:0] actual_next2=x2_taking ? branch_target2 : x2_pc+4;
    wire prediction_wrong2=x2_valid && actual_next2!=x2_predicted;
    wire [31:0] alu2_result;
    wire misaligned2=(x2_load || x2_store) && ((x2_insn[13:12]==1 && alu2_result[0]) || (x2_insn[13:12]==2 && |alu2_result[1:0]));
    wire ex2_trap=x2_valid && ((x2_taking && |branch_target2[1:0]) || misaligned2);
    wire [31:0] ex2_cause=(x2_taking && |branch_target2[1:0])?32'd0:x2_store?32'd6:32'd4;
    wire [31:0] ex2_tval=(x2_taking && |branch_target2[1:0])?branch_target2:alu2_result;
    wire [3:0] access_mask2=x2_insn[13:12]==0 ? (4'b0001<<alu2_result[1:0]) : x2_insn[13:12]==1 ? (4'b0011<<alu2_result[1:0]) : 4'b1111;
    wire [31:0] store_value2=x2_insn[13:12]==0 ? ({24'b0,operand22[7:0]}<<(8*alu2_result[1:0])) :
                             x2_insn[13:12]==1 ? ({16'b0,operand22[15:0]}<<(8*alu2_result[1:0])) : operand22;
    rv32_alu alu_second(.a(x2_pc_a?x2_pc:operand21),.b(x2_imm_b?x2_imm:operand22),.op(x2_alu),.result(alu2_result));
    wire [31:0] alu_a = x_pc_a ? x_pc : operand1;
    wire [31:0] alu_b = x_imm_b ? x_imm : operand2;
    wire [31:0] alu_result;
    rv32_alu alu (.a(alu_a), .b(alu_b), .op(x_alu), .result(alu_result));

    // MEM: EX/MEM pipeline register. Requests exist only in this stage.
    reg m_valid, m_we, m_load, m_store, m_trap;
    reg [31:0] m_pc, m_insn, m_next_pc, m_value, m_addr;
    reg [31:0] m_wdata, m_cause, m_tval;
    reg [4:0] m_rd;
    reg [3:0] m_wmask, m_rmask;
    reg [2:0] m_f3;
    reg m_taken,m_prediction_hit,m_prediction_taken,m_prediction_wrong;
    // WB: MEM/WB pipeline register. Architectural register state changes here.
    reg w_valid, w_we, w_trap;
    reg [31:0] w_pc, w_insn, w_next_pc, w_value, w_addr;
    reg [31:0] w_wdata, w_rdata, w_cause, w_tval;
    reg [4:0] w_rd;
    reg [3:0] w_wmask, w_rmask;
    reg w_taken,w_prediction_hit,w_prediction_taken,w_prediction_wrong;
    // Simulation/debug counters. Unconnected outputs are optimized away in the
    // normal board build; these are not advertised as readable hardware CSRs.
    reg [63:0] bp_cf_retired,bp_hits,bp_taken_predictions,bp_mispredictions;
    reg [63:0] bp_conditional_retired,bp_direction_misses;
    wire w_control=w_insn[6:0]==7'h63 || w_insn[6:0]==7'h6f || w_insn[6:0]==7'h67;
    wire w2_control=w2_insn[6:0]==7'h63 || w2_insn[6:0]==7'h6f || w2_insn[6:0]==7'h67;
    wire bp_second=retire2_valid && w2_control;
    wire [31:0] bp_committed_insn=bp_second?w2_insn:w_insn;
    wire bp_committed_hit=bp_second?w2_hit:w_prediction_hit;
    wire bp_committed_pred_taken=bp_second?w2_pred_taken:w_prediction_taken;
    wire bp_committed_taken=bp_second?w2_taken:w_taken;
    wire bp_committed_wrong=bp_second?w2_wrong:w_prediction_wrong;
    assign bp_update_valid=(retire_valid && !retire_trap && w_control) || bp_second;
    assign bp_update_conditional=bp_committed_insn[6:0]==7'h63;
    assign bp_update_taken=bp_committed_taken;
    assign bp_update_pc=bp_second?w2_pc:w_pc;
    assign bp_update_target=bp_second?w2_next_pc:w_next_pc;
    assign bp_update_insn=bp_committed_insn;
    assign bp_update_index=bp_second?w2_index:w_prediction_index;

    assign retire_valid = w_valid && !halted && !rst;
    assign retire2_valid=DUAL_ENABLE && retire_valid && w2_valid && !w_trap && !w2_trap;
    assign retire2_mem_addr=retire2_valid && (|w2_wmask || |w2_rmask)?w2_addr:32'b0;
    assign retire2_mem_wmask=retire2_valid?w2_wmask:4'b0;
    assign retire2_mem_rmask=retire2_valid?w2_rmask:4'b0;
    assign retire2_mem_wdata=retire2_valid && |w2_wmask?w2_wdata:32'b0;
    assign retire2_mem_rdata=retire2_valid && |w2_rmask?w2_rdata:32'b0;
    assign retire2_rd_we=retire2_valid && w2_we && w2_rd!=0;
    assign retire2_pc=w2_pc;
    assign retire2_insn=w2_insn;
    assign retire2_next_pc=w2_next_pc;
    assign retire2_rd=retire2_rd_we?w2_rd:5'b0;
    assign retire2_rd_data=retire2_rd_we?w2_value:32'b0;
    assign retire_trap = retire_valid && w_trap;
    assign retire_rd_we = retire_valid && w_we && !w_trap && w_rd != 0;
    assign retire_pc = w_pc;
    assign retire_insn = w_insn;
    assign retire_next_pc = w_trap ? {csr_mtvec[31:2],2'b00} : w_next_pc;
    assign retire_rd = retire_rd_we ? w_rd : 5'b0;
    assign retire_rd_data = retire_rd_we ? w_value : 32'b0;
    assign retire_mem_addr = (!w_trap && (|w_wmask || |w_rmask)) ? w_addr : 32'b0;
    assign retire_mem_wmask = w_trap ? 4'b0 : w_wmask;
    assign retire_mem_rmask = w_trap ? 4'b0 : w_rmask;
    assign retire_mem_wdata = (!w_trap && |w_wmask) ? w_wdata : 32'b0;
    assign retire_mem_rdata = (!w_trap && |w_rmask) ? w_rdata : 32'b0;
    assign retire_cause = w_trap ? w_cause : 32'b0;
    assign retire_tval = w_trap ? w_tval : 32'b0;
    assign halting = w_valid && w_trap && !rst;
    assign secondary_exception_pending=w_valid && w2_trap && !w_trap && !rst;
    wire x_csr = x_insn[6:0]==7'h73 && (x_f3==1 || x_f3==2 || x_f3==3 || x_f3==5 || x_f3==6 || x_f3==7);
    wire x_mret = x_insn==32'h30200073;
    wire x_system = x_csr || x_mret || x_insn==32'h10500073;
    wire m_system = m_insn[6:0]==7'h73 && !m_trap;
    wire w_csr = w_insn[6:0]==7'h73 && w_insn[14:12]!=0 && w_insn[14:12]!=4;
    wire w_system = w_insn[6:0]==7'h73 && !w_trap;
    wire x_csr_write = x_f3[1:0]==1 || x_rs1!=0;
    wire [31:0] x_csr_operand = x_f3[2] ? {27'b0,x_rs1} : operand1;
    wire [31:0] x_csr_new = x_f3[1:0]==1 ? x_csr_operand :
                           x_f3[1:0]==2 ? csr_read_data | x_csr_operand : csr_read_data & ~x_csr_operand;
    assign csr_commit = w_valid && w_csr && !w_trap && !rst && (w_insn[13:12]==1 || w_insn[19:15]!=0);
    assign returning = w_valid && w_insn==32'h30200073 && !w_trap && !rst;
    assign irq_hold = irq_draining || irq_enabled;
    assign irq_boundary = irq_hold && !x_valid && !m_valid && !w_valid && !rst;
    assign interrupt_taken = irq_boundary && irq_enabled;
    assign trap_target = {csr_mtvec[31:2],2'b00} + ((interrupt_taken && csr_mtvec[1:0]==1) ? 32'd28 : 32'd0);
    wire serial_block = (id_system && (x_valid || m_valid || w_valid)) ||
                        (x_valid && x_system) || (m_valid && m_system) || (w_valid && w_system);
    rv32_csr #(.RESET_MTVEC(RESET_MTVEC),.IMPL_ID(32'h00020000 | (M_ENABLE<<16) | (BP_INDEX_BITS<<8) | (DUAL_ENABLE<<2) | (WIDE_FETCH<<3) | (PAIR_JALR<<1) | (PAIR_BRANCH<<4) | (PAIR_MEMORY<<5) | (FAST_STORE<<6) | (FAST_MUL<<7) | (PAIR_MUL<<13) | BP_ENABLE),.M_ENABLE(M_ENABLE && DIV_ENABLE),
        .UARCH_CONFIG(32'hf1000000 | (BP_INDEX_BITS<<20) | (FETCH_DEPTH<<16) | (RAS_DEPTH<<8) | (PHT_BITS<<4) | (FETCH_BYPASS<<2) | (LOAD_FORWARD<<1) | GSHARE_ENABLE),
        .ISSUE_CONFIG(32'hd1000000 | (DUAL_ENABLE<<0) | (WIDE_FETCH<<1))) csrfile (
        .clk(clk),.rst(rst),.read_address(x_insn[31:20]),.read_data(csr_read_data),
        .known(csr_known),.read_only(csr_readonly),.write_enable(csr_commit),
        .write_address(w_insn[31:20]),.write_data(w_addr),
        .trap_enter(halting || interrupt_taken),.trap_epc(interrupt_taken ? arch_next_pc : w_pc),
        .trap_cause(interrupt_taken ? 32'h80000007 : w_cause),.trap_value(interrupt_taken ? 32'b0 : w_tval),
        .mret(returning),.irq_timer(irq_timer),.irq_enabled(irq_enabled),
        .mtvec(csr_mtvec),.mepc(csr_mepc),.cycle_count(cycles),.retired_count(instret),.count_inhibit(count_inhibit),
        .issued_pair_count(issue_pairs),.retired_pair_count(retired_pairs)
    );

    wire memory_in_second=m2_valid && (m2_load || m2_store);
    wire memory_request=m_load || m_store || (memory_in_second && !m2_trap);
    assign dmem_valid=m_valid && memory_request && !m_trap && !halted && !halting && !secondary_exception_pending && !rst;
    assign dmem_write=memory_in_second?m2_store:m_store;
    assign dmem_addr=memory_in_second?m2_addr:m_addr;
    assign dmem_wdata=memory_in_second?m2_wdata:m_wdata;
    assign dmem_wstrb=memory_in_second?m2_wmask:m_wmask;
    wire m_done=m_valid && (m_trap || !memory_request || dmem_ready);
    wire bus_fault=dmem_valid && dmem_ready && dmem_error;
    wire m_fault=bus_fault && !memory_in_second;
    wire m2_fault=bus_fault && memory_in_second;
    wire m_slot=!m_valid || m_done;
    wire load_available=LOAD_FORWARD && dmem_valid && m_load && dmem_ready && !dmem_error;
    wire load_available2=LOAD_FORWARD && dmem_valid && memory_in_second && m2_load && dmem_ready && !dmem_error;
    wire load_dependency0=x_valid && m_valid && m_load && !m_trap && m_rd!=0 &&
         ((x_use1 && x_rs1==m_rd) || (x_use2 && x_rs2==m_rd) || (x2_valid && ((x2_use1 && x2_rs1==m_rd) || (x2_use2 && x2_rs2==m_rd))));
    wire load_dependency2=x_valid && m_valid && m2_valid && m2_load && !m_trap && !m2_trap && m2_rd!=0 &&
         ((x_use1 && x_rs1==m2_rd) || (x_use2 && x_rs2==m2_rd) || (x2_valid && ((x2_use1 && x2_rs1==m2_rd) || (x2_use2 && x2_rs2==m2_rd))));
    wire load_dependency=load_dependency0 || load_dependency2;
    wire load_hazard=(load_dependency0 && !load_available) || (load_dependency2 && !load_available2);
    // Faulting fetch data is unspecified: it must never wait for an M result.
    wire x_mop=M_ENABLE && !x_trap && x_insn[6:0]==7'h33 && x_insn[31:25]==7'h01;
    wire x2_mop=M_ENABLE && x2_valid && x2_insn[6:0]==7'h33 && x2_insn[31:25]==1;
    wire any_mop=x_mop || x2_mop;
    wire md_ready,md_valid;
    wire [31:0] md_result;
    reg md_issued;
    wire md_kill=halting || returning || irq_boundary || secondary_exception_pending;
    // Pending interrupts must allow the existing EX instruction to finish.
    wire md_request=x_valid && any_mop && !x_trap && !load_hazard && !md_issued && !halted && !md_kill;
    wire x_fire = x_valid && m_slot && !load_hazard && (!any_mop || md_valid) && !halted && !halting && !returning && !secondary_exception_pending;
    generate if(M_ENABLE) begin: m_extension
        rv32_muldiv #(.FAST_MUL(FAST_MUL),.DIV_ENABLE(DIV_ENABLE)) unit(.clk(clk),.rst(rst),.kill(md_kill),.req_valid(md_request),.req_ready(md_ready),
            .req_op(x2_mop?x2_insn[14:12]:x_f3),.req_a(x2_mop?operand21:operand1),.req_b(x2_mop?operand22:operand2),.rsp_valid(md_valid),.rsp_ready(x_fire && any_mop),.result(md_result));
    end else begin: m_disabled
        assign md_ready=1'b0; assign md_valid=1'b0; assign md_result=32'b0;
    end endgenerate
    always @(posedge clk) begin
        if(rst || md_kill || x_fire) md_issued<=0;
        else if(md_request && md_ready) md_issued<=1;
    end
    assign id_ready = (!x_valid || x_fire) && !halting && !returning && !redirect && !serial_block && !irq_hold && !secondary_exception_pending;

    always @* begin
        operand1=x_r1;operand2=x_r2;operand21=x2_r1;operand22=x2_r2;
        if(retire_rd_we) begin
            if(x_use1 && x_rs1==w_rd) operand1=w_value;
            if(x_use2 && x_rs2==w_rd) operand2=w_value;
            if(x2_use1 && x2_rs1==w_rd) operand21=w_value;
            if(x2_use2 && x2_rs2==w_rd) operand22=w_value;
        end
        if(retire2_rd_we) begin
            if(x_use1 && x_rs1==w2_rd) operand1=w2_value;
            if(x_use2 && x_rs2==w2_rd) operand2=w2_value;
            if(x2_use1 && x2_rs1==w2_rd) operand21=w2_value;
            if(x2_use2 && x2_rs2==w2_rd) operand22=w2_value;
        end
        if(m_valid && m_we && (!m_load || load_available) && !m_trap && m_rd!=0) begin
            if(x_use1 && x_rs1==m_rd) operand1=m_load?load_value:m_value;
            if(x_use2 && x_rs2==m_rd) operand2=m_load?load_value:m_value;
            if(x2_use1 && x2_rs1==m_rd) operand21=m_load?load_value:m_value;
            if(x2_use2 && x2_rs2==m_rd) operand22=m_load?load_value:m_value;
        end
        if(m_valid && m2_valid && m2_we && (!m2_load || load_available2) && !m_trap && !m2_trap && m2_rd!=0) begin
            if(x_use1 && x_rs1==m2_rd) operand1=m2_load?load_value:m2_value;
            if(x_use2 && x_rs2==m2_rd) operand2=m2_load?load_value:m2_value;
            if(x2_use1 && x2_rs1==m2_rd) operand21=m2_load?load_value:m2_value;
            if(x2_use2 && x2_rs2==m2_rd) operand22=m2_load?load_value:m2_value;
        end
    end

    reg branch_taken;
    always @* begin
        case (x_f3)
            3'd0: branch_taken = operand1 == operand2;
            3'd1: branch_taken = operand1 != operand2;
            3'd4: branch_taken = $signed(operand1) < $signed(operand2);
            3'd5: branch_taken = $signed(operand1) >= $signed(operand2);
            3'd6: branch_taken = operand1 < operand2;
            3'd7: branch_taken = operand1 >= operand2;
            default: branch_taken = 0;
        endcase
    end
    wire taking_branch = x_jal || x_jalr || (x_branch && branch_taken);
    wire [31:0] branch_target = x_jalr ? ((operand1 + x_imm) & 32'hfffffffe) : x_pc + x_imm;
    wire data_misaligned = (x_load || x_store) &&
                           ((x_f3[1:0] == 1 && alu_result[0]) ||
                            (x_f3[1:0] == 2 && |alu_result[1:0]));
    reg ex_trap;
    reg [31:0] ex_cause, ex_tval;
    always @* begin
        ex_trap = x_trap; ex_cause = x_cause; ex_tval = x_tval;
        if (!x_trap && x_csr && (!csr_known || (x_csr_write && csr_readonly))) begin
            ex_trap = 1; ex_cause = 2; ex_tval = x_insn;
        end else if (!x_trap && taking_branch && |branch_target[1:0]) begin
            ex_trap = 1; ex_cause = 0; ex_tval = branch_target;
        end else if (!x_trap && data_misaligned) begin
            ex_trap = 1; ex_cause = x_store ? 32'd6 : 32'd4; ex_tval = alu_result;
        end
    end
    wire [31:0] actual_next_pc=taking_branch ? branch_target : x_pc+32'd4;
    wire prediction_wrong=actual_next_pc!=x_predicted_next_pc;
    wire prediction_recovery=x_fire && !ex_trap && !x_mret && !ex2_trap && !secondary_exception_pending && (prediction_wrong || prediction_wrong2);
    assign redirect = halting || returning || irq_boundary || prediction_recovery;
    assign redirect_pc = halting ? trap_target : returning ? csr_mepc :
                         irq_boundary ? (irq_enabled ? trap_target : arch_next_pc) : prediction_wrong ? actual_next_pc : actual_next2;

    reg [3:0] access_mask;
    reg [31:0] store_value;
    always @* begin
        case (x_f3[1:0])
            2'd0: begin
                access_mask = 4'b0001 << alu_result[1:0];
                store_value = {24'b0,operand2[7:0]} << (8 * alu_result[1:0]);
            end
            2'd1: begin
                access_mask = 4'b0011 << alu_result[1:0];
                store_value = {16'b0,operand2[15:0]} << (8 * alu_result[1:0]);
            end
            default: begin access_mask = 4'b1111; store_value = operand2; end
        endcase
    end
    wire [31:0] shifted_load = dmem_rdata >> (8 * dmem_addr[1:0]);
    always @* begin
        case (memory_in_second?m2_f3:m_f3)
            3'd0: load_value = {{24{shifted_load[7]}},shifted_load[7:0]};
            3'd1: load_value = {{16{shifted_load[15]}},shifted_load[15:0]};
            3'd2: load_value = shifted_load;
            3'd4: load_value = {24'b0,shifted_load[7:0]};
            3'd5: load_value = {16'b0,shifted_load[15:0]};
            default: load_value = 0;
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            halted <= 0; trap_pc <= 0; trap_cause <= 0; trap_tval <= 0;
            x2_valid<=0;x2_use1<=0;x2_use2<=0;x2_we<=0;x2_pc_a<=0;x2_imm_b<=0;
            x2_pc<=0;x2_insn<=0;x2_r1<=0;x2_r2<=0;x2_imm<=0;x2_rs1<=0;x2_rs2<=0;x2_rd<=0;x2_alu<=0;
            m2_valid<=0;m2_we<=0;m2_pc<=0;m2_insn<=0;m2_value<=0;m2_rd<=0;
            w2_valid<=0;w2_we<=0;w2_pc<=0;w2_insn<=0;w2_value<=0;w2_rd<=0;
            issue_pairs<=0;retired_pairs<=0;
            m2_load<=0;m2_store<=0;m2_trap<=0;w2_trap<=0;
            m2_addr<=0;m2_wdata<=0;m2_cause<=0;m2_tval<=0;w2_addr<=0;w2_wdata<=0;w2_rdata<=0;w2_cause<=0;w2_tval<=0;
            m2_wmask<=0;m2_rmask<=0;w2_wmask<=0;w2_rmask<=0;m2_f3<=0;
            x2_predicted<=0;m2_next_pc<=0;w2_next_pc<=0;
            x2_hit<=0;x2_taken_pred<=0;x2_ras<=0;m2_ras<=0;w2_ras<=0;m2_hit<=0;m2_pred_taken<=0;m2_taken<=0;m2_wrong<=0;
            w2_hit<=0;w2_pred_taken<=0;w2_taken<=0;w2_wrong<=0;x2_index<=0;m2_index<=0;w2_index<=0;
            irq_draining <= 0; arch_next_pc <= RESET_PC;
            cycles <= 0; instret <= 0; load_stall_cycles <= 0;
            bp_cf_retired<=0; bp_hits<=0; bp_taken_predictions<=0; bp_mispredictions<=0;
            bp_conditional_retired<=0; bp_direction_misses<=0;
            x_predicted_next_pc<=RESET_PC+4; x_prediction_hit<=0; x_prediction_taken<=0; x_prediction_ras<=0;
            x_prediction_index<=0; m_prediction_index<=0; w_prediction_index<=0; m_prediction_ras<=0; w_prediction_ras<=0;
            m_taken<=0; m_prediction_hit<=0; m_prediction_taken<=0; m_prediction_wrong<=0;
            w_taken<=0; w_prediction_hit<=0; w_prediction_taken<=0; w_prediction_wrong<=0;
            data_wait_cycles <= 0; fetch_wait_cycles <= 0; redirect_count <= 0;
            x_valid <= 0; x_pc <= 0; x_insn <= 0; x_r1 <= 0; x_r2 <= 0;
            x_imm <= 0; x_cause <= 0; x_tval <= 0;
            x_rs1 <= 0; x_rs2 <= 0; x_rd <= 0; x_alu <= 0; x_f3 <= 0;
            x_use1 <= 0; x_use2 <= 0; x_we <= 0; x_pc_a <= 0; x_imm_b <= 0;
            x_load <= 0; x_store <= 0; x_branch <= 0; x_jal <= 0; x_jalr <= 0; x_trap <= 0;
            m_valid <= 0; m_we <= 0; m_load <= 0; m_store <= 0; m_trap <= 0;
            m_pc <= 0; m_insn <= 0; m_next_pc <= 0; m_value <= 0; m_addr <= 0;
            m_wdata <= 0; m_cause <= 0; m_tval <= 0; m_rd <= 0;
            m_wmask <= 0; m_rmask <= 0; m_f3 <= 0;
            w_valid <= 0; w_we <= 0; w_trap <= 0;
            w_pc <= 0; w_insn <= 0; w_next_pc <= 0; w_value <= 0; w_addr <= 0;
            w_wdata <= 0; w_rdata <= 0; w_cause <= 0; w_tval <= 0; w_rd <= 0;
            w_wmask <= 0; w_rmask <= 0;
        end else begin
            if(bp_update_valid) begin
                bp_cf_retired<=bp_cf_retired+1;
                if(bp_committed_hit) bp_hits<=bp_hits+1;
                if(bp_committed_pred_taken) bp_taken_predictions<=bp_taken_predictions+1;
                if(bp_committed_wrong) bp_mispredictions<=bp_mispredictions+1;
                if(bp_committed_insn[6:0]==7'h63) begin
                    bp_conditional_retired<=bp_conditional_retired+1;
                    if(bp_committed_pred_taken!=bp_committed_taken) bp_direction_misses<=bp_direction_misses+1;
                end
            end
            if(id_valid && id_ready && issue_pair) issue_pairs<=issue_pairs+1;
            if(retire2_valid) retired_pairs<=retired_pairs+1;
            if (!count_inhibit[0]) cycles <= cycles + 1;
            if (retire_valid && !retire_trap && !count_inhibit[2]) instret <= instret + 64'd1 + (retire2_valid?64'd1:64'd0);
            // Explicit counter writes override that instruction's implicit increment.
            if (csr_commit) case (w_insn[31:20])
                12'hb00: cycles <= {cycles[63:32],w_addr};
                12'hb80: cycles <= {w_addr,cycles[31:0]};
                12'hb02: instret <= {instret[63:32],w_addr};
                12'hb82: instret <= {w_addr,instret[31:0]};
                default: begin end
            endcase
            if (retire_valid && !retire_trap) arch_next_pc <= retire2_valid ? retire2_next_pc : w_next_pc;
            if (halting || returning || irq_boundary) irq_draining <= 0;
            else if (irq_enabled) irq_draining <= 1;
            if (!halted && load_hazard) load_stall_cycles <= load_stall_cycles + 1;
            if (dmem_valid && !dmem_ready) data_wait_cycles <= data_wait_cycles + 1;
            if (imem_valid && !imem_ready) fetch_wait_cycles <= fetch_wait_cycles + 1;
            if (redirect) redirect_count <= redirect_count + 1;
            if (halting || returning || irq_boundary) begin
                arch_next_pc <= redirect_pc;
                if (halting || interrupt_taken) begin
                    trap_pc <= interrupt_taken ? arch_next_pc : w_pc;
                    trap_cause <= interrupt_taken ? 32'h80000007 : w_cause;
                    trap_tval <= interrupt_taken ? 32'b0 : w_tval;
                end
                x_valid <= 0; m_valid <= 0; w_valid <= 0; x2_valid<=0;m2_valid<=0;w2_valid<=0;w2_trap<=0;
            end else if(secondary_exception_pending) begin
                // Retire the older normal instruction now; present the younger
                // exception on the primary retirement port in the next cycle.
                // No younger bus request or MDU operation may escape this step.
                x_valid<=0;x2_valid<=0;m_valid<=0;m2_valid<=0;
                w_valid<=1;w2_valid<=0;w2_trap<=0;w_we<=0;w_trap<=1;
                w_pc<=w2_pc;w_insn<=w2_insn;w_next_pc<=w2_pc+4;w_value<=0;w_addr<=0;w_rd<=0;
                w_wmask<=0;w_rmask<=0;w_wdata<=0;w_rdata<=0;w_cause<=w2_cause;w_tval<=w2_tval;
                w_prediction_hit<=0;w_prediction_taken<=0;w_prediction_wrong<=0;w_taken<=0;
            end else if (!halted) begin
                // WB always drains; no instruction can retire twice during a stall.
                w_valid <= m_done;
                w2_valid<=m_done && m2_valid && !m_trap && !m_fault && !m2_trap && !m2_fault;
                w2_trap<=m_done && m2_valid && !m_trap && !m_fault && (m2_trap || m2_fault);
                if (m_done) begin
                    w2_ras<=m2_ras;w2_next_pc<=m2_next_pc;w2_hit<=m2_hit;w2_pred_taken<=m2_pred_taken;w2_taken<=m2_taken;w2_wrong<=m2_wrong;w2_index<=m2_index;
                    w2_addr<=m2_addr;w2_wdata<=m2_wdata;w2_rdata<=dmem_rdata;w2_wmask<=m2_wmask;w2_rmask<=m2_rmask;
                    w2_cause<=m2_fault?(m2_store?32'd7:32'd5):m2_cause;w2_tval<=m2_fault?m2_addr:m2_tval;
                    w2_pc<=m2_pc;w2_insn<=m2_insn;w2_value<=m2_load?load_value:m2_value;w2_rd<=m2_rd;w2_we<=m2_we;
                    w_prediction_index<=m_prediction_index; w_prediction_ras<=m_prediction_ras;
                    w_taken<=m_taken; w_prediction_hit<=m_prediction_hit;
                    w_prediction_taken<=m_prediction_taken; w_prediction_wrong<=m_prediction_wrong;
                    w_pc <= m_pc; w_insn <= m_insn; w_next_pc <= m_next_pc;
                    w_rd <= m_rd; w_we <= m_we;
                    w_value <= m_load ? load_value : m_value;
                    w_addr <= m_addr; w_wmask <= m_wmask; w_rmask <= m_rmask;
                    w_wdata <= m_wdata; w_rdata <= dmem_rdata;
                    w_trap <= m_trap || m_fault;
                    w_cause <= m_fault ? (m_store ? 32'd7 : 32'd5) : m_cause;
                    w_tval <= m_fault ? m_addr : m_tval;
                end
                if (m_slot) begin
                    m_valid <= x_fire;
                    m2_valid<=x_fire && x2_valid && !ex_trap;
                    if (x_fire) begin
                        m2_ras<=x2_ras;m2_next_pc<=actual_next2;m2_hit<=x2_hit;m2_pred_taken<=x2_taken_pred;m2_taken<=x2_taking;m2_wrong<=prediction_wrong2;m2_index<=x2_index;
                        m2_load<=x2_load;m2_store<=x2_store;m2_trap<=ex2_trap;m2_cause<=ex2_cause;m2_tval<=ex2_tval;
                        m2_addr<=alu2_result;m2_wdata<=store_value2;m2_wmask<=x2_store?access_mask2:4'b0;m2_rmask<=x2_load?access_mask2:4'b0;m2_f3<=x2_insn[14:12];
                        m2_pc<=x2_pc;m2_insn<=x2_insn;m2_value<=x2_mop?md_result:(x2_jal || x2_jalr)?x2_pc+4:alu2_result;m2_rd<=x2_rd;m2_we<=x2_we;
                        m_prediction_index<=x_prediction_index; m_prediction_ras<=x_prediction_ras;
                        m_taken<=taking_branch; m_prediction_hit<=x_prediction_hit;
                        m_prediction_taken<=x_prediction_taken; m_prediction_wrong<=prediction_wrong;
                        m_pc <= x_pc; m_insn <= x_insn;
                        m_next_pc <= x_mret ? csr_mepc : taking_branch ? branch_target : x_pc + 4;
                        m_rd <= x_rd; m_we <= x_we;
                        m_value <= x_mop ? md_result : x_csr ? csr_read_data : (x_jal || x_jalr) ? x_pc + 4 : alu_result;
                        m_addr <= x_csr ? x_csr_new : alu_result; m_load <= x_load; m_store <= x_store;
                        m_wdata <= store_value;
                        m_wmask <= x_store ? access_mask : 4'b0;
                        m_rmask <= x_load ? access_mask : 4'b0;
                        m_f3 <= x_f3; m_trap <= ex_trap; m_cause <= ex_cause; m_tval <= ex_tval;
                    end
                end
                if (redirect) begin x_valid <= 0;x2_valid<=0;end
                else if (!x_valid || x_fire) begin
                    x_valid <= id_valid && id_ready;
                    x2_valid<=id_valid && id_ready && issue_pair;
                    if (id_valid && id_ready) begin
                        x2_predicted<=id2_next_pc;x2_hit<=id2_hit;x2_taken_pred<=id2_taken;x2_ras<=id2_ras;x2_index<=id2_index;
                        x2_pc<=id2_pc;x2_insn<=id2_insn;x2_r1<=id2_r1;x2_r2<=id2_r2;x2_imm<=id2_imm;
                        x2_rs1<=id2_rs1;x2_rs2<=id2_rs2;x2_rd<=id2_rd;x2_alu<=id2_alu;
                        x2_use1<=id2_use1;x2_use2<=id2_use2;x2_we<=id2_we;x2_pc_a<=id2_pc_a;x2_imm_b<=id2_imm_b;
                        x_prediction_index<=id_prediction_index; x_prediction_ras<=id_prediction_ras;
                        x_predicted_next_pc<=id_predicted_next_pc;
                        x_prediction_hit<=id_prediction_hit; x_prediction_taken<=id_prediction_taken;
                        x_pc <= id_pc; x_insn <= id_insn;
                        x_rs1 <= id_rs1; x_rs2 <= id_rs2; x_rd <= id_rd;
                        x_r1 <= id_r1; x_r2 <= id_r2; x_imm <= id_imm;
                        x_use1 <= id_use1 || (id_csr && !id_f3[2]); x_use2 <= id_use2; x_we <= id_we || id_csr;
                        x_alu <= id_alu; x_pc_a <= id_pc_a; x_imm_b <= id_imm_b;
                        x_load <= id_load; x_store <= id_store; x_branch <= id_branch;
                        x_jal <= id_jal; x_jalr <= id_jalr; x_f3 <= id_f3;
                        x_trap <= id_fetch_error || (id_illegal && !id_system) || id_ecall || id_ebreak;
                        if (id_fetch_error) begin x_cause <= 1; x_tval <= id_pc; end
                        else if (id_illegal && !id_system) begin x_cause <= 2; x_tval <= id_insn; end
                        else if (id_ebreak) begin x_cause <= 3; x_tval <= id_pc; end
                        else if (id_ecall) begin x_cause <= 11; x_tval <= 0; end
                        else begin x_cause <= 0; x_tval <= 0; end
                    end
                end else begin
                    // Preserve a WB bypass while EX is held by a slow memory.
                    // WB may disappear next cycle; retaining stale ID data is wrong.
                    x_r1 <= operand1;
                    x_r2 <= operand2;
                    x2_r1<=operand21;x2_r2<=operand22;
                end
            end
        end
    end
endmodule
