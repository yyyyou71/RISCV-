`default_nettype none
// One CPU-owned RGB888 tensor and matching RGB565 frame lease. The tensor lives
// in the CPU/AI logical DDR region; raw frame addresses keep the reference layout.
module hdmi_tensor_capture #(
    parameter integer CORE_TIMEOUT_CYCLES=16000000,
    parameter integer PIXEL_TIMEOUT_CYCLES=8000000
)(
    input wire clk,core_clk,pixel_clk,rst_n,ddr_ready,shared_fault,
    input wire dev_we,
    input wire [7:0] dev_addr_wr,dev_addr_rd,
    input wire [31:0] dev_wdata,
    output reg [31:0] read_data,
    input wire vs,de,source_ready,
    input wire [23:0] rgb,
    input wire [31:0] source_next_id,
    input wire raw_begin,raw_accepted,raw_end,raw_end_ok,
    input wire [31:0] raw_begin_id,raw_end_id,
    input wire [2:0] raw_begin_slot,raw_end_slot,
    output wire [4:0] hold_mask,
    output wire fault,
    output wire [27:0] axi_awaddr,
    output wire axi_awvalid,axi_awap,
    output wire [3:0] axi_awlen,axi_awid,
    input wire axi_awready,axi_wready,axi_wlast,
    input wire [3:0] axi_wid,
    output wire [127:0] axi_wdata,
    output wire [15:0] axi_wstrb
);
    localparam [31:0] TENSOR_BYTES=294912;
    localparam [7:0] E_CONFIG=1,E_RAW_DROP=2,E_RAW_MISSING=3,E_RAW_BAD=4,
        E_TIMEOUT=5,E_DDR=6,E_COUNT=7,E_HELD=8;
    localparam [2:0] IDLE=0,RESET_FIFO=1,ARM=2,RUN=3,HELD=4;
    reg request,release_request,cpu_busy,cpu_done,cpu_error,cpu_held;
    reg [31:0] cfg_base,cpu_id,cpu_bytes;
    reg [2:0] cpu_slot;
    reg [7:0] cpu_code;
    reg ack,response_error,response_held;
    reg [7:0] response_code;
    reg [31:0] response_id,response_bytes;
    reg [2:0] response_slot;
    (* ASYNC_REG="TRUE" *) reg req_meta,req_sync,ack_meta,ack_sync;
    (* ASYNC_REG="TRUE" *) reg ready_meta,ready_sync,fault_meta,fault_sync;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            request<=0;release_request<=0;cpu_busy<=0;cpu_done<=0;cpu_error<=0;cpu_held<=0;
            cfg_base<=32'h03f00000;cpu_id<=0;cpu_bytes<=0;cpu_slot<=0;cpu_code<=0;
            ack_meta<=0;ack_sync<=0;ready_meta<=0;ready_sync<=0;fault_meta<=0;fault_sync<=0;
        end else begin
            ack_meta<=ack;ack_sync<=ack_meta;ready_meta<=ddr_ready;ready_sync<=ready_meta;
            fault_meta<=fault||shared_fault;fault_sync<=fault_meta;
            if(cpu_busy && ack_sync==request) begin
                cpu_busy<=0;cpu_done<=1;cpu_error<=response_error;cpu_held<=response_held;
                cpu_code<=response_code;cpu_id<=response_id;cpu_slot<=response_slot;cpu_bytes<=response_bytes;
            end
            if(dev_we && !cpu_busy) begin
                if(dev_addr_wr==8'h10 && !cpu_held) cfg_base<=dev_wdata;
                if(dev_addr_wr==0) begin
                    if(dev_wdata==4) begin cpu_done<=0;cpu_error<=0;cpu_code<=0;end
                    else if(dev_wdata==1 && cpu_held) begin cpu_done<=1;cpu_error<=1;cpu_code<=E_HELD;end
                    else if(dev_wdata==1 || dev_wdata==2) begin
                        request<=!request;release_request<=dev_wdata==2;
                        cpu_busy<=1;cpu_done<=0;cpu_error<=0;cpu_code<=0;
                    end
                end
            end
        end
    end
    always @* begin
        read_data=0;
        case(dev_addr_rd)
            8'h04:read_data={26'b0,fault_sync,ready_sync,cpu_held,cpu_error,cpu_done,cpu_busy};
            8'h08:read_data=cpu_id;
            8'h0c:read_data={29'b0,cpu_slot};
            8'h10:read_data=cfg_base;
            8'h14:read_data=TENSOR_BYTES;
            8'h18:read_data={24'b0,cpu_code};
            8'h1c:read_data=cpu_bytes;
            8'h20:read_data={7'b0,cpu_slot,22'b0}; // raw-frame native base
            default:read_data=0;
        endcase
    end

    reg [2:0] state;
    reg [4:0] reset_count;
    reg job_reset_n,core_start,core_cancel,core_held,raw_complete,target_valid,pixel_seen;
    reg aborting,locked_fault,dma_active;
    reg [31:0] base,written,timer,target_id;
    reg [15:0] abort_timer;
    reg [2:0] held_slot;
    reg [7:0] result_code;
    assign hold_mask=core_held ? (5'b1<<held_slot):5'b0;
    assign fault=locked_fault||dma_fault;

    // A job owns its FIFO until all accepted DDR commands and pixel work end.
    // Reset is asserted between jobs in both domains; release is synchronized.
    (* ASYNC_REG="TRUE" *) reg [1:0] pixel_reset;
    always @(posedge pixel_clk or negedge job_reset_n)
        if(!job_reset_n)pixel_reset<=0;else pixel_reset<={pixel_reset[0],1'b1};
    wire pixel_reset_n=pixel_reset[1];
    (* ASYNC_REG="TRUE" *) reg start_meta,start_sync,cancel_meta,cancel_sync;
    reg started,sof_level,pixel_done,pixel_pending;
    reg [7:0] pixel_code;
    wire pool_ready,pool_busy,pool_sof,pool_done,pool_error,pool_valid,pool_last;
    wire [3:0] pool_code;
    wire [31:0] pool_id;
    wire [15:0] pool_beats;
    wire [127:0] pool_data;
    reg serial_busy;
    reg [2:0] serial_lane;
    reg [127:0] serial_data;
    wire fifo_full,fifo_empty,ip_empty,ip_rd_en;
    wire [9:0] ip_level;
    wire [10:0] fifo_level={1'b0,ip_level}+{10'b0,head_valid};
    wire [127:0] fifo_data;
    reg head_valid;
    wire pool_accept=pool_valid&&!serial_busy&&!fifo_full;
    wire start_pool=start_sync&&!started&&source_ready&&pool_ready&&!cancel_sync;
    rgb888_pool96 #(.TIMEOUT_CYCLES(PIXEL_TIMEOUT_CYCLES)) u_pool(
        .clk(pixel_clk),.rst_n(pixel_reset_n),.start(start_pool),.cancel(cancel_sync),
        .vs(vs),.de(de),.rgb(rgb),.source_frame_id(source_next_id),
        .ready(pool_ready),.busy(pool_busy),.frame_start(pool_sof),.done(pool_done),
        .error(pool_error),.error_code(pool_code),.result_frame_id(pool_id),
        .out_valid(pool_valid),.out_ready(!serial_busy&&!fifo_full),.out_data(pool_data),
        .out_last(pool_last),.out_beats(pool_beats));
    always @(posedge pixel_clk or negedge pixel_reset_n) begin
        if(!pixel_reset_n) begin
            start_meta<=0;start_sync<=0;cancel_meta<=0;cancel_sync<=0;
            started<=0;sof_level<=0;pixel_done<=0;pixel_pending<=0;pixel_code<=0;
            serial_busy<=0;serial_lane<=0;serial_data<=0;
        end else begin
            start_meta<=core_start;start_sync<=start_meta;cancel_meta<=core_cancel;cancel_sync<=cancel_meta;
            if(start_pool)started<=1;
            if(pool_sof)sof_level<=1;
            if(pool_accept)begin serial_data<=pool_data;serial_lane<=0;serial_busy<=1;end
            else if(serial_busy&&!fifo_full)begin
                if(serial_lane==7)serial_busy<=0;else serial_lane<=serial_lane+1'b1;
            end
            if(pool_done)begin pixel_pending<=1;pixel_code<=pool_error ? (8'h10|{4'b0,pool_code}):8'd0;end
            if(cancel_sync&&!pool_busy)begin pixel_pending<=1;end
            if(pixel_pending&&!serial_busy)pixel_done<=1;
        end
    end
    // Reuse the reference vendor FIFO (16-bit write, 128-bit read). Serializing
    // 8 lanes per word takes at most 18 clocks for the 2 words of one pooled
    // pixel; pooled pixels are separated by 20 source clocks even at row ends.
    fifo_2_ddr u_tensor_fifo(
        .wr_clk(pixel_clk),.wr_rst(!pixel_reset_n),.wr_en(serial_busy&&!fifo_full),
        .wr_data(serial_data[serial_lane*16+:16]),.wr_full(fifo_full),.almost_full(),
        .rd_clk(core_clk),.rd_rst(!job_reset_n),.rd_en(ip_rd_en),.rd_data(fifo_data),
        .rd_empty(ip_empty),.almost_empty(),.rd_water_level(ip_level));
    assign fifo_empty=!head_valid;
    assign ip_rd_en=job_reset_n&&!ip_empty&&(!head_valid||dma_push);
    always @(posedge core_clk or negedge job_reset_n)
        if(!job_reset_n)head_valid<=0;
        else if(ip_rd_en)head_valid<=1;
        else if(dma_push)head_valid<=0;
    (* ASYNC_REG="TRUE" *) reg sof_meta,sof_sync,done_meta,done_sync;
    always @(posedge core_clk or negedge job_reset_n)
        if(!job_reset_n)begin sof_meta<=0;sof_sync<=0;done_meta<=0;done_sync<=0;end
        else begin sof_meta<=sof_level;sof_sync<=sof_meta;done_meta<=pixel_done;done_sync<=done_meta;end

    wire dma_ready,dma_busy,dma_done,dma_error,dma_fault,dma_wr_ready;
    wire [3:0] dma_code;
    wire dma_valid=state==RUN&&!aborting&&!shared_fault&&ddr_ready&&!dma_active&&
        written<TENSOR_BYTES&&fifo_level>=16;
    wire dma_push=dma_wr_ready&&!fifo_empty;
    wire [31:0] physical_address=32'h04000000+base+written;
    ddr_block_transfer #(.AXI_ID(4'd2),.TIMEOUT_CYCLES(65536)) u_transfer(
        .core_clk(core_clk),.rst_n(rst_n),.ddr_init_done(ddr_ready),
        .cmd_valid(dma_valid),.cmd_ready(dma_ready),.cmd_write(1'b1),
        .cmd_addr(physical_address),.cmd_len(32'd256),.clear_status(1'b0),
        .busy(dma_busy),.done(dma_done),.error(dma_error),.error_code(dma_code),.fault(dma_fault),
        .wr_valid(!fifo_empty),.wr_ready(dma_wr_ready),.wr_data(fifo_data),
        .rd_valid(),.rd_ready(1'b0),.rd_data(),.rd_last(),
        .axi_awaddr(axi_awaddr),.axi_awuser_ap(axi_awap),.axi_awuser_id(axi_awid),
        .axi_awlen(axi_awlen),.axi_awvalid(axi_awvalid),.axi_awready(axi_awready),
        .axi_wdata(axi_wdata),.axi_wstrb(axi_wstrb),.axi_wready(axi_wready),
        .axi_wusero_id(axi_wid),.axi_wusero_last(axi_wlast),
        .axi_araddr(),.axi_aruser_ap(),.axi_aruser_id(),.axi_arlen(),.axi_arvalid(),
        .axi_arready(1'b0),.axi_rdata(128'b0),.axi_rid(4'b0),.axi_rlast(1'b0),.axi_rvalid(1'b0));
    wire target_known=target_valid||sof_sync;
    wire [31:0] target_now=target_valid ? target_id:pool_id;
    wire config_bad=cfg_base[7:0]!=0 || {1'b0,cfg_base}+33'd294912>33'h04000000;
    always @(posedge core_clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;req_meta<=0;req_sync<=0;ack<=0;
            response_error<=0;response_held<=0;response_code<=0;response_id<=0;response_slot<=0;response_bytes<=0;
            reset_count<=0;job_reset_n<=0;core_start<=0;core_cancel<=0;core_held<=0;
            raw_complete<=0;target_valid<=0;pixel_seen<=0;aborting<=0;locked_fault<=0;dma_active<=0;
            base<=0;written<=0;timer<=0;target_id<=0;abort_timer<=0;held_slot<=0;result_code<=0;
        end else begin
            req_meta<=request;req_sync<=req_meta;
            case(state)
                IDLE,HELD: if(req_sync!=ack)begin
                    if(release_request)begin
                        core_held<=0;job_reset_n<=0;response_held<=0;response_error<=0;response_code<=0;
                        core_start<=0;core_cancel<=0;ack<=req_sync;state<=IDLE;
                    end else if(config_bad||!ddr_ready||shared_fault||fault)begin
                        response_error<=1;response_held<=0;response_code<=config_bad ? E_CONFIG:E_DDR;
                        response_bytes<=0;ack<=req_sync;
                    end else begin
                        base<=cfg_base;written<=0;timer<=0;reset_count<=0;abort_timer<=0;
                        job_reset_n<=0;core_start<=0;core_cancel<=0;core_held<=0;
                        raw_complete<=0;target_valid<=0;pixel_seen<=0;aborting<=0;dma_active<=0;
                        result_code<=0;response_error<=0;response_held<=0;state<=RESET_FIFO;
                    end
                end
                RESET_FIFO: if(reset_count==15)begin job_reset_n<=1;reset_count<=0;state<=ARM;end
                    else reset_count<=reset_count+1'b1;
                ARM: if(reset_count==7)begin core_start<=1;state<=RUN;end
                    else reset_count<=reset_count+1'b1;
                RUN: begin
                    if(timer<CORE_TIMEOUT_CYCLES)timer<=timer+1'b1;
                    if(sof_sync&&!target_valid)begin target_valid<=1;target_id<=pool_id;end
                    if(raw_begin&&target_known&&!core_held)begin
                        if(raw_begin_id==target_now)begin
                            if(raw_accepted)begin core_held<=1;held_slot<=raw_begin_slot;end
                            else begin aborting<=1;result_code<=E_RAW_DROP;end
                        end else if($signed(raw_begin_id-target_now)>0)begin aborting<=1;result_code<=E_RAW_MISSING;end
                    end
                    if(raw_end&&core_held&&raw_end_id==target_now&&raw_end_slot==held_slot)begin
                        raw_complete<=raw_end_ok;
                        if(!raw_end_ok)begin aborting<=1;result_code<=E_RAW_BAD;end
                    end
                    if(done_sync&&!pixel_seen)begin
                        pixel_seen<=1;
                        if(pixel_code!=0)begin aborting<=1;result_code<=pixel_code;end
                        else if(!target_known||pool_id!=target_now||pool_beats!=18432)begin
                            aborting<=1;result_code<=E_COUNT;
                        end
                    end
                    if(dma_valid&&dma_ready)dma_active<=1;
                    if(dma_active&&dma_done)begin
                        dma_active<=0;
                        if(dma_error)begin aborting<=1;result_code<=E_DDR;end
                        else written<=written+256;
                    end
                    if(!ddr_ready||shared_fault)begin aborting<=1;result_code<=E_DDR;end
                    else if(timer==CORE_TIMEOUT_CYCLES-1)begin aborting<=1;result_code<=E_TIMEOUT;end
                    if(aborting)begin
                        core_cancel<=1;
                        if(abort_timer!=65535)abort_timer<=abort_timer+1'b1;
                    end
                    if(dma_fault || (aborting&&abort_timer==65535))begin
                        locked_fault<=1;job_reset_n<=0;core_start<=0;core_held<=0;
                        response_error<=1;response_held<=0;response_code<=E_DDR;
                        response_bytes<=written;ack<=req_sync;state<=IDLE;
                    end else if(aborting&&!dma_active&&!dma_busy&&done_sync)begin
                        job_reset_n<=0;core_start<=0;core_held<=0;response_error<=1;response_held<=0;
                        response_code<=result_code;response_bytes<=written;ack<=req_sync;state<=IDLE;
                    end else if(!aborting&&pixel_seen&&raw_complete&&written==TENSOR_BYTES&&!dma_active&&ddr_ready&&!shared_fault)begin
                        response_error<=0;response_held<=1;response_code<=0;
                        response_id<=target_id;response_slot<=held_slot;response_bytes<=written;
                        ack<=req_sync;state<=HELD;
                    end
                end
                default:state<=IDLE;
            endcase
        end
    end
    wire unused=^{pool_last,dma_code};
endmodule
`default_nettype wire
