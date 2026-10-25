`timescale 1ns/1ps
// M-only CSR subset. All CSR accesses are serialized by the CPU and write at WB.
module rv32_csr #(parameter [31:0] RESET_MTVEC=0, parameter [31:0] IMPL_ID=32'h00020501, parameter integer M_ENABLE=0, parameter [31:0] UARCH_CONFIG=0, parameter [31:0] ISSUE_CONFIG=32'hd1000000)(
    input wire clk,rst,
    input wire [11:0] read_address,
    output reg [31:0] read_data,
    output reg known,read_only,
    input wire write_enable,
    input wire [11:0] write_address,
    input wire [31:0] write_data,
    input wire trap_enter,
    input wire [31:0] trap_epc,trap_cause,trap_value,
    input wire mret,irq_timer,
    output wire irq_enabled,
    output reg [31:0] mtvec,mepc,
    input wire [63:0] cycle_count,retired_count,
    input wire [31:0] issued_pair_count,retired_pair_count,
    output reg [31:0] count_inhibit
);
    reg status_mie,status_mpie,timer_enable;
    reg [31:0] mscratch,mcause,mtval;
    wire [31:0] status_word=32'h00001800 | (status_mie?32'h8:0) | (status_mpie?32'h80:0);
    assign irq_enabled=status_mie && timer_enable && irq_timer;
    always @* begin
        known=1; read_only=read_address[11:10]==2'b11; read_data=0;
        case(read_address)
            12'h300: read_data=status_word;
            12'h301: read_data=32'h40000100 | (M_ENABLE ? 32'h00001000 : 0); // Fixed WARL: RV32 I or IM.
            12'h304: read_data=timer_enable?32'h80:0;
            12'h305: read_data=mtvec;
            12'h306,12'h310: read_data=0; // M-only mcounteren, little-endian mstatush.
            12'h320: read_data=count_inhibit;
            12'h340: read_data=mscratch;
            12'h341: read_data=mepc;
            12'h342: read_data=mcause;
            12'h343: read_data=mtval;
            12'h344: read_data=irq_timer?32'h80:0; // MTIP field is read-only.
            12'hb00,12'hc00: read_data=cycle_count[31:0];
            12'hb80,12'hc80: read_data=cycle_count[63:32];
            12'hb02,12'hc02: read_data=retired_count[31:0];
            12'hb82,12'hc82: read_data=retired_count[63:32];
            12'hf11,12'hf12,12'hf14: read_data=0;
            12'hf13: read_data=IMPL_ID;
            12'hfc1: read_data=ISSUE_CONFIG;
            12'hfc2: read_data=issued_pair_count;
            12'hfc3: read_data=retired_pair_count;
            12'hfc0: read_data=UARCH_CONFIG; // Custom machine read-only configuration.
            default: known=0;
        endcase
    end
    always @(posedge clk) begin
        if(rst) begin
            status_mie<=0; status_mpie<=0; timer_enable<=0;
            mtvec<={RESET_MTVEC[31:2],2'b00}; mepc<=0;
            mscratch<=0; mcause<=0; mtval<=0; count_inhibit<=0;
        end else if(trap_enter) begin
            mepc<={trap_epc[31:2],2'b00}; mcause<=trap_cause; mtval<=trap_value;
            status_mpie<=status_mie; status_mie<=0;
        end else if(mret) begin
            status_mie<=status_mpie; status_mpie<=1;
        end else if(write_enable) begin
            case(write_address)
                12'h300: begin status_mie<=write_data[3]; status_mpie<=write_data[7]; end
                12'h304: timer_enable<=write_data[7];
                12'h305: mtvec<={write_data[31:2],1'b0,(write_data[1:0]==1)};
                12'h320: count_inhibit<=write_data & 32'h5;
                12'h340: mscratch<=write_data;
                12'h341: mepc<={write_data[31:2],2'b00};
                12'h342: mcause<=write_data;
                12'h343: mtval<=write_data;
                // misa/mcounteren/mstatush are fixed WARL; mip.MTIP ignores writes.
                // Counter writes are handled by the owning CPU counter registers.
                default: begin end
            endcase
        end
    end
endmodule
