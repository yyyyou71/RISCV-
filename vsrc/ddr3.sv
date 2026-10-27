// Simulation-only Pango Logos2 HMIC_S 1.10 native-interface replacement.
// Original implementation, derived from public interface declarations and UG042003.
// See docs/ddr3_usage_report.md for supported contract and deliberate timing limits.
`timescale 1ns/1ps
`ifndef DDR3_MODEL_SLOTS
`define DDR3_MODEL_SLOTS 65536
`endif
module ddr3 #(
   parameter MEM_ROW_WIDTH       = 15          ,
   parameter MEM_COLUMN_WIDTH    = 10          ,
   parameter MEM_BANK_WIDTH      = 3           ,
  parameter MEM_DQ_WIDTH         =  16         ,
  parameter MEM_DM_WIDTH         =  2         ,
  parameter MEM_DQS_WIDTH        =  2         ,
   parameter CTRL_ADDR_WIDTH     = MEM_ROW_WIDTH + MEM_COLUMN_WIDTH + MEM_BANK_WIDTH
  )(
   input                              ref_clk                       ,
   input                              resetn                        ,
   output                             core_clk                      ,
   output                             pll_lock                      ,
   output                             phy_pll_lock                  ,
   output                             gpll_lock                     ,
   output                             rst_gpll_lock                 ,
   output                             ddrphy_cpd_lock               ,
   output                             ddr_init_done                 ,
   input  [CTRL_ADDR_WIDTH-1:0]       axi_awaddr                    ,
   input                              axi_awuser_ap                 ,
   input  [3:0]                       axi_awuser_id                 ,
   input  [3:0]                       axi_awlen                     ,
   output                             axi_awready                   ,
   input                              axi_awvalid                   ,
   input  [8*MEM_DQ_WIDTH-1:0]        axi_wdata                     ,
   input  [MEM_DQ_WIDTH-1:0]          axi_wstrb                     ,
   output                             axi_wready                    ,
   output [3:0]                       axi_wusero_id                 ,
   output                             axi_wusero_last               ,
   input  [CTRL_ADDR_WIDTH-1:0]       axi_araddr                    ,
   input                              axi_aruser_ap                 ,
   input  [3:0]                       axi_aruser_id                 ,
   input  [3:0]                       axi_arlen                     ,
   output                             axi_arready                   ,
   input                              axi_arvalid                   ,
   output [8*MEM_DQ_WIDTH-1:0]        axi_rdata                     ,
   output [3:0]                       axi_rid                       ,
   output                             axi_rlast                     ,
   output                             axi_rvalid                    ,
   input                              apb_clk                       ,
   input                              apb_rst_n                     ,
   input                              apb_sel                       ,
   input                              apb_enable                    ,
   input  [7:0]                       apb_addr                      ,
   input                              apb_write                     ,
   output                             apb_ready                     ,
   input  [15:0]                      apb_wdata                     ,
   output [15:0]                      apb_rdata                     ,
   output                             mem_rst_n                     ,
   output                             mem_ck                        ,
   output                             mem_ck_n                      ,
   output                             mem_cke                       ,
   output                             mem_ras_n                     ,
   output                             mem_cas_n                     ,
   output                             mem_we_n                      ,
   output                             mem_odt                       ,
   output [MEM_ROW_WIDTH-1:0]         mem_a                         ,
   output [MEM_BANK_WIDTH-1:0]        mem_ba                        ,
   inout  [MEM_DQS_WIDTH-1:0]         mem_dqs                       ,
   inout  [MEM_DQS_WIDTH-1:0]         mem_dqs_n                     ,
   inout  [MEM_DQ_WIDTH-1:0]          mem_dq                        ,
   output [MEM_DM_WIDTH-1:0]          mem_dm                        ,
   input                              dbg_gate_start                ,
   input                              dbg_cpd_start                 ,
   input                              dbg_ddrphy_rst_n              ,
   input                              dbg_gpll_scan_rst             ,
   input                              samp_position_dyn_adj         ,
   input  [8*MEM_DQS_WIDTH-1:0]       init_samp_position_even       ,
   input  [8*MEM_DQS_WIDTH-1:0]       init_samp_position_odd        ,
   input                              wrcal_position_dyn_adj        ,
   input  [8*MEM_DQS_WIDTH-1:0]       init_wrcal_position           ,
   input                              force_read_clk_ctrl           ,
   input  [4*MEM_DQS_WIDTH-1:0]       init_slip_step                ,
   input  [3*MEM_DQS_WIDTH-1:0]       init_read_clk_ctrl            ,
   output [33:0]                      debug_calib_ctrl              ,
   output [17*MEM_DQS_WIDTH -1:0]     dbg_slice_status              ,
   output [22*MEM_DQS_WIDTH -1:0]     dbg_slice_state               ,
   output [69*MEM_DQS_WIDTH -1:0]     debug_data                    ,
   output [1:0]                       dbg_dll_upd_state             ,
   output [8:0]                       debug_gpll_dps_phase          ,
   output [2:0]                       dbg_rst_dps_state             ,
   output [5:0]                       dbg_tran_err_rst_cnt          ,
   output                             dbg_ddrphy_init_fail          ,
   input                              debug_cpd_offset_adj          ,
   input                              debug_cpd_offset_dir          ,
   input  [9:0]                       debug_cpd_offset              ,
   output [9:0]                       debug_dps_cnt_dir0            ,
   output [9:0]                       debug_dps_cnt_dir1            ,
   input                              ck_dly_en                     ,
   input  [7:0]                       init_ck_dly_step              ,
   output [7:0]                       ck_dly_set_bin                ,
   output                             align_error                   ,
   output [3:0]                       debug_rst_state               ,
   output [3:0]                       debug_cpd_state
);
    localparam integer DATA_BITS = 8 * MEM_DQ_WIDTH;
    localparam integer BYTE_LANES = MEM_DQ_WIDTH;
    localparam integer SLOTS = `DDR3_MODEL_SLOTS;
    localparam integer QUEUE_DEPTH = 16;

    // These are simulation controls, deliberately absent from the IP parameters.
    integer init_cycles = 32, read_latency = 6, write_latency = 3;
    integer stall_every = 0, stall_cycles = 1, random_stalls = 0;
    integer zero_init = 0, seed = 1;
    real core_period_ns = 7.619;
    reg generated_clk = 0;
`ifdef DDR3_MODEL_EXTERNAL_CORE_CLOCK
    // Useful for untimed Verilator C++ drivers. ref_clk must then be the UI clock.
    assign core_clk = ref_clk;
`else
    assign core_clk = generated_clk;
    initial begin
        if (!$value$plusargs("ddr3_core_period_ns=%f", core_period_ns)) core_period_ns = 7.619;
        if (core_period_ns <= 0.002) $fatal(1, "DDR3: invalid core period");
        @(posedge ref_clk);
        forever #(core_period_ns / 2.0) generated_clk = ~generated_clk;
    end
`endif

    reg initialized = 0;
    integer startup_count = 0, cycle_number = 0;
    reg [31:0] rng = 1;
    wire periodic_stall = (stall_every > 0) &&
                          ((cycle_number % ((stall_every > 0) ? stall_every : 1)) < stall_cycles);
    wire aw_stall = periodic_stall || (random_stalls != 0 && rng[2:0] == 0);
    wire ar_stall = periodic_stall || (random_stalls != 0 && rng[5:3] == 0);
    wire w_stall  = periodic_stall || (random_stalls != 0 && rng[8:6] == 0);
    wire r_stall  = periodic_stall || (random_stalls != 0 && rng[11:9] == 0);
    assign ddr_init_done = initialized && resetn;
    assign pll_lock = resetn && startup_count >= 2;
    assign phy_pll_lock = pll_lock;
    assign gpll_lock = resetn && startup_count >= 3;
    assign rst_gpll_lock = gpll_lock;
    assign ddrphy_cpd_lock = resetn && startup_count >= 4;

    // Sparse, tagged storage covers the WHOLE native address space. An exhausted
    // table fails explicitly; it never silently aliases high addresses into RAM.
    reg occupied [0:SLOTS-1];
    reg [CTRL_ADDR_WIDTH-1:0] tags [0:SLOTS-1];
    reg [DATA_BITS-1:0] contents [0:SLOTS-1];
    integer init_index;
    initial begin
        // Use the return value: older Verilator can otherwise optimize out a
        // plusarg call whose result is repeatedly assigned to an unused integer.
        if (!$value$plusargs("ddr3_init_cycles=%d", init_cycles)) init_cycles = 32;
        if (!$value$plusargs("ddr3_read_latency=%d", read_latency)) read_latency = 6;
        if (!$value$plusargs("ddr3_write_latency=%d", write_latency)) write_latency = 3;
        if (!$value$plusargs("ddr3_stall_every=%d", stall_every)) stall_every = 0;
        if (!$value$plusargs("ddr3_stall_cycles=%d", stall_cycles)) stall_cycles = 1;
        if (!$value$plusargs("ddr3_random_stalls=%d", random_stalls)) random_stalls = 0;
        if (!$value$plusargs("ddr3_zero_init=%d", zero_init)) zero_init = 0;
        if (!$value$plusargs("ddr3_seed=%d", seed)) seed = 1;
        if (CTRL_ADDR_WIDTH != MEM_ROW_WIDTH + MEM_COLUMN_WIDTH + MEM_BANK_WIDTH ||
            MEM_COLUMN_WIDTH < 3 || MEM_DQ_WIDTH < 8 || MEM_DQ_WIDTH % 8 != 0 ||
            MEM_DQS_WIDTH != MEM_DQ_WIDTH / 8 || MEM_DM_WIDTH != MEM_DQS_WIDTH ||
            CTRL_ADDR_WIDTH > 30 || SLOTS < 1)
            $fatal(1, "DDR3: inconsistent geometry");
        if (init_cycles < 5 || read_latency < 0 || write_latency < 0 ||
            stall_every < 0 || stall_cycles < 0 ||
            (stall_every > 0 && stall_cycles >= stall_every) || seed == 0)
            $fatal(1, "DDR3: invalid simulation controls");
        for (init_index = 0; init_index < SLOTS; init_index = init_index + 1)
            occupied[init_index] = 0;
    end

    function automatic integer find_slot(input [CTRL_ADDR_WIDTH-1:0] address);
        integer slot, probes;
        reg [CTRL_ADDR_WIDTH-1:0] tag;
        begin
            tag = address >> 3;
            slot = (int'(tag) ^ (int'(tag) >> 13)) % SLOTS;
            probes = 0;
            while (probes < SLOTS && occupied[slot] && tags[slot] != tag) begin
                slot = (slot + 1) % SLOTS;
                probes = probes + 1;
            end
            find_slot = (probes == SLOTS) ? -1 : slot;
        end
    endfunction

    function automatic [DATA_BITS-1:0] load_word(input [CTRL_ADDR_WIDTH-1:0] address);
        integer slot;
        begin
            slot = find_slot(address);
            if (slot >= 0 && occupied[slot]) load_word = contents[slot];
            else begin
                // 网络对拍可启用严格模式；Verilator两态仿真不能靠X值发现漏装载。
                // 只检查整个字未曾写入的情况；部分字节有效性仍须四态仿真检查。
`ifdef DDR3_MODEL_STRICT_READS
                $fatal(1, "DDR3: read of uninitialized word at native address %h", address);
`endif
                load_word = (zero_init != 0) ? {DATA_BITS{1'b0}} : {DATA_BITS{1'bx}};
            end
        end
    endfunction

    task automatic store_word(input [CTRL_ADDR_WIDTH-1:0] address,
                              input [DATA_BITS-1:0] data,
                              input [BYTE_LANES-1:0] strobe);
        integer slot, lane;
        begin
            if (strobe != 0) begin
                slot = find_slot(address);
                if (slot < 0) $fatal(1, "DDR3: sparse table full; increase DDR3_MODEL_SLOTS");
                if (!occupied[slot]) begin
                    occupied[slot] = 1;
                    tags[slot] = address >> 3;
                    contents[slot] = (zero_init != 0) ? {DATA_BITS{1'b0}} : {DATA_BITS{1'bx}};
                end
                for (lane = 0; lane < BYTE_LANES; lane = lane + 1) begin
                    if (strobe[lane]) begin
                        if ($isunknown(data[lane*8 +: 8]))
                            $fatal(1, "DDR3: unknown enabled write byte at native address %h", address);
                        contents[slot][lane*8 +: 8] = data[lane*8 +: 8];
                    end
                end
            end
        end
    endtask

    function automatic [CTRL_ADDR_WIDTH-1:0] following_word(input [CTRL_ADDR_WIDTH-1:0] address);
        reg [MEM_COLUMN_WIDTH-1:0] column;
        begin
            column = address[MEM_COLUMN_WIDTH-1:0] + MEM_COLUMN_WIDTH'(8);
            // UG042003 2.8.2: column wraps; bank and row do NOT carry.
            following_word = {address[CTRL_ADDR_WIDTH-1:MEM_COLUMN_WIDTH], column};
        end
    endfunction

    reg [CTRL_ADDR_WIDTH-1:0] aw_address [0:QUEUE_DEPTH-1], ar_address [0:QUEUE_DEPTH-1];
    reg [3:0] aw_length [0:QUEUE_DEPTH-1], ar_length [0:QUEUE_DEPTH-1];
    reg [3:0] aw_id [0:QUEUE_DEPTH-1], ar_id [0:QUEUE_DEPTH-1];
    integer aw_head = 0, aw_tail = 0, aw_count = 0;
    integer ar_head = 0, ar_tail = 0, ar_count = 0;
    reg writing = 0, reading = 0;
    reg [CTRL_ADDR_WIDTH-1:0] write_address, read_address;
    reg [3:0] write_id, read_id;
    integer write_left = 0, read_left = 0, write_wait = 0, read_wait = 0;
    reg [DATA_BITS-1:0] read_data_q = 0;
    reg [3:0] read_id_q = 0;
    reg read_valid_q = 0, read_last_q = 0;

    // APB register subset: MR0..MR3, CTRL_MODE_DATA, STATUS_REG_DATA.
    // Timing and MR application are functional abstractions, not PHY emulation.
    reg [15:0] mr0 = 16'h1930, mr1 = 16'h0014, mr2 = 16'h0008;
    reg [15:0] ctrl_mode = 0;
    reg [1:0] requested_mode = 0, mode_state = 0;
    reg request_toggle = 0, ack_toggle = 0;
    reg request_s1 = 0, request_s2 = 0, ack_s1 = 0, ack_s2 = 0;
    reg [1:0] mode_s1 = 0, mode_s2 = 0;
    wire apb_busy = request_toggle != ack_s2;
    wire normal_mode = mode_state == 0 && request_s2 == ack_toggle;
    assign apb_ready = apb_rst_n && apb_sel && apb_enable;
    assign apb_rdata = apb_addr == 0 ? mr0 : apb_addr == 1 ? mr1 :
                       apb_addr == 2 ? mr2 : apb_addr == 3 ? 16'h0000 :
                       apb_addr == 4 ? ctrl_mode :
                       apb_addr == 5 ? {apb_busy, 13'b0, mode_s2} : 16'h0000;
    always @(posedge apb_clk or negedge apb_rst_n) begin
        if (!apb_rst_n) begin
            mr0 <= 16'h1930; mr1 <= 16'h0014; mr2 <= 16'h0008;
            ctrl_mode <= 0; requested_mode <= 0; request_toggle <= 0;
            ack_s1 <= 0; ack_s2 <= 0; mode_s1 <= 0; mode_s2 <= 0;
        end else begin
            ack_s1 <= ack_toggle; ack_s2 <= ack_s1;
            mode_s1 <= mode_state; mode_s2 <= mode_s1;
            if (apb_ready) begin
                if (apb_addr > 5) $fatal(1, "DDR3: unsupported APB register %h", apb_addr);
                if (apb_write) begin
                    case (apb_addr)
                        0: mr0 <= (mr0 & ~16'h0e7c) | (apb_wdata & 16'h0e7c);
                        1: mr1 <= (mr1 & ~16'h0266) | (apb_wdata & 16'h0266);
                        2: mr2 <= (mr2 & ~16'h0638) | (apb_wdata & 16'h0638);
                        3: ; // MR3 is reserved/read-only in this configuration.
                        4: begin
                            ctrl_mode <= apb_wdata & 16'hc001;
                            if (apb_wdata[0]) begin
                                if (apb_busy) $fatal(1, "DDR3: APB mode request while busy");
                                requested_mode <= apb_wdata[15:14];
                                request_toggle <= ~request_toggle;
                            end
                        end
                        default: ; // Status is read-only.
                    endcase
                end
            end
        end
    end

    assign axi_awready = ddr_init_done && normal_mode && aw_count < QUEUE_DEPTH && !aw_stall;
    assign axi_arready = ddr_init_done && normal_mode && ar_count < QUEUE_DEPTH && !ar_stall;
    assign axi_wready = ddr_init_done && writing && write_wait == 0 && !w_stall;
    assign axi_wusero_id = write_id;
    assign axi_wusero_last = axi_wready && write_left == 1;
    assign axi_rdata = read_data_q;
    assign axi_rid = read_id_q;
    assign axi_rlast = read_last_q && resetn;
    assign axi_rvalid = read_valid_q && resetn;
    wire push_aw = axi_awvalid && axi_awready;
    wire push_ar = axi_arvalid && axi_arready;
    wire pop_aw = ddr_init_done && !writing && aw_count != 0;
    wire pop_ar = ddr_init_done && !reading && ar_count != 0;
    wire emit_read = ddr_init_done && reading && read_wait == 0 && !r_stall;

    reg held_aw = 0, held_ar = 0;
    reg [CTRL_ADDR_WIDTH+8:0] held_aw_payload, held_ar_payload;
    wire [CTRL_ADDR_WIDTH+8:0] aw_payload = {axi_awaddr, axi_awuser_ap, axi_awuser_id, axi_awlen};
    wire [CTRL_ADDR_WIDTH+8:0] ar_payload = {axi_araddr, axi_aruser_ap, axi_aruser_id, axi_arlen};
    always @(posedge core_clk or negedge resetn) begin
        if (!resetn) begin
            initialized <= 0; startup_count <= 0; cycle_number <= 0; rng <= 32'(seed);
            aw_head <= 0; aw_tail <= 0; aw_count <= 0;
            ar_head <= 0; ar_tail <= 0; ar_count <= 0;
            writing <= 0; reading <= 0; write_left <= 0; read_left <= 0;
            write_wait <= 0; read_wait <= 0; write_address <= 0; read_address <= 0;
            write_id <= 0; read_id <= 0;
            read_valid_q <= 0; read_last_q <= 0; read_data_q <= 0; read_id_q <= 0;
            held_aw <= 0; held_ar <= 0;
            request_s1 <= 0; request_s2 <= 0; ack_toggle <= 0; mode_state <= 0;
            // Reset aborts queued/in-progress commands. It never erases storage.
        end else begin
            cycle_number <= cycle_number + 1;
            rng <= {rng[30:0], rng[31] ^ rng[21] ^ rng[1] ^ rng[0]};
            if (startup_count < init_cycles) startup_count <= startup_count + 1;
            if (startup_count >= init_cycles - 1) initialized <= 1;
            request_s1 <= request_toggle; request_s2 <= request_s1;
            if (ddr_init_done && request_s2 != ack_toggle &&
                !writing && !reading && aw_count == 0 && ar_count == 0) begin
                case (requested_mode)
                    0: mode_state <= 0;
                    1: mode_state <= 3;
                    2: mode_state <= 1;
                    3: mode_state <= 2;
                endcase
                ack_toggle <= request_s2;
            end
            if (held_aw && (!axi_awvalid || aw_payload !== held_aw_payload))
                $fatal(1, "DDR3: AW changed/withdrawn before handshake");
            if (held_ar && (!axi_arvalid || ar_payload !== held_ar_payload))
                $fatal(1, "DDR3: AR changed/withdrawn before handshake");
            held_aw <= axi_awvalid && !axi_awready;
            held_ar <= axi_arvalid && !axi_arready;
            held_aw_payload <= aw_payload; held_ar_payload <= ar_payload;
            if (push_aw) begin
                if ($isunknown(aw_payload) || axi_awaddr[2:0] != 0)
                    $fatal(1, "DDR3: AW must be known and BL8 aligned (native low 3 bits zero)");
                aw_address[aw_tail] <= axi_awaddr; aw_length[aw_tail] <= axi_awlen;
                aw_id[aw_tail] <= axi_awuser_id;
                aw_tail <= (aw_tail + 1) % QUEUE_DEPTH;
            end
            if (push_ar) begin
                if ($isunknown(ar_payload) || axi_araddr[2:0] != 0)
                    $fatal(1, "DDR3: AR must be known and BL8 aligned (native low 3 bits zero)");
                ar_address[ar_tail] <= axi_araddr; ar_length[ar_tail] <= axi_arlen;
                ar_id[ar_tail] <= axi_aruser_id;
                ar_tail <= (ar_tail + 1) % QUEUE_DEPTH;
            end
            case ({push_aw, pop_aw})
                2'b10: aw_count <= aw_count + 1;
                2'b01: aw_count <= aw_count - 1;
                default: ;
            endcase
            case ({push_ar, pop_ar})
                2'b10: ar_count <= ar_count + 1;
                2'b01: ar_count <= ar_count - 1;
                default: ;
            endcase
            if (pop_aw) begin
                writing <= 1; write_address <= aw_address[aw_head];
                write_left <= int'(aw_length[aw_head]) + 1; write_id <= aw_id[aw_head];
                write_wait <= write_latency; aw_head <= (aw_head + 1) % QUEUE_DEPTH;
            end else if (writing) begin
                if (write_wait > 0) write_wait <= write_wait - 1;
                if (axi_wready) begin
                    if ($isunknown(axi_wstrb)) $fatal(1, "DDR3: unknown WSTRB");
                    store_word(write_address, axi_wdata, axi_wstrb);
                    write_address <= following_word(write_address);
                    write_left <= write_left - 1;
                    if (write_left == 1) writing <= 0;
                end
            end
            read_valid_q <= 0; read_last_q <= 0;
            if (pop_ar) begin
                reading <= 1; read_address <= ar_address[ar_head];
                read_left <= int'(ar_length[ar_head]) + 1; read_id <= ar_id[ar_head];
                read_wait <= read_latency; ar_head <= (ar_head + 1) % QUEUE_DEPTH;
            end else if (reading) begin
                if (read_wait > 0) read_wait <= read_wait - 1;
                if (emit_read) begin
                    if (axi_wready && write_address == read_address)
                        $fatal(1, "DDR3: unordered simultaneous read/write of same word");
                    read_valid_q <= 1; read_data_q <= load_word(read_address);
                    read_id_q <= read_id; read_last_q <= read_left == 1;
                    read_address <= following_word(read_address); read_left <= read_left - 1;
                    if (read_left == 1) reading <= 0;
                end
            end
            if (dbg_gate_start === 1'b1 || dbg_cpd_start === 1'b1 ||
                dbg_ddrphy_rst_n === 1'b0 || dbg_gpll_scan_rst === 1'b1 ||
                samp_position_dyn_adj === 1'b1 || wrcal_position_dyn_adj === 1'b1 ||
                force_read_clk_ctrl === 1'b1 || debug_cpd_offset_adj === 1'b1 || ck_dly_en === 1'b1)
                $fatal(1, "DDR3: PHY calibration/debug controls are outside this transaction model");
        end
    end

    // Pin-level DDR is intentionally idle. Do not attach a DDR chip model.
    assign mem_rst_n = resetn;
    assign mem_ck = core_clk; assign mem_ck_n = ~core_clk;
    assign mem_cke = ddr_init_done && mode_state != 1 && mode_state != 2;
    assign mem_ras_n = 1; assign mem_cas_n = 1; assign mem_we_n = 1;
    assign mem_odt = 0; assign mem_a = 0; assign mem_ba = 0; assign mem_dm = 0;
    assign mem_dq = {MEM_DQ_WIDTH{1'bz}};
    assign mem_dqs = {MEM_DQS_WIDTH{1'bz}};
    assign mem_dqs_n = {MEM_DQS_WIDTH{1'bz}};
    assign debug_calib_ctrl = 0; assign dbg_slice_status = 0; assign dbg_slice_state = 0;
    assign debug_data = 0; assign dbg_dll_upd_state = 0; assign debug_gpll_dps_phase = 0;
    assign dbg_rst_dps_state = 0; assign dbg_tran_err_rst_cnt = 0;
    assign dbg_ddrphy_init_fail = 0; assign debug_dps_cnt_dir0 = 0;
    assign debug_dps_cnt_dir1 = 0; assign ck_dly_set_bin = 0;
    assign align_error = 0; assign debug_rst_state = 0; assign debug_cpd_state = 0;
endmodule
