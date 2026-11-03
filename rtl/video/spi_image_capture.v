`default_nettype none
// One committed RGBX image -> retained RGB565 slot 0 + optional pooled tensor.
// The shared DDR native port is owned for complete bursts. No external video
// clock, next-frame delimiter or CPU pixel processing is required.
module spi_image_capture #(
    parameter integer WIDTH=384,HEIGHT=216
)(
    input wire clk,core_clk,rst_n,ddr_ready,shared_fault,
    input wire [4:0] external_hold,
    input wire dev_we,
    input wire [7:0] addr_wr,addr_rd,
    input wire [31:0] wdata,
    output reg [31:0] rdata,
    output wire active,held,available,fault,
    output wire [31:0] frame_id,
    output wire [27:0] axi_awaddr,axi_araddr,
    output wire axi_awvalid,axi_arvalid,axi_awap,axi_arap,
    output wire [3:0] axi_awlen,axi_arlen,axi_awid,axi_arid,
    input wire axi_awready,axi_arready,axi_wready,axi_wlast,axi_rvalid,axi_rlast,
    input wire [3:0] axi_wid,axi_rid,
    output wire [127:0] axi_wdata,
    output wire [15:0] axi_wstrb,
    input wire [127:0] axi_rdata
);
    localparam [31:0] INPUT_BYTES=WIDTH*HEIGHT*4,RAW_BYTES=WIDTH*HEIGHT*2,TENSOR_BYTES=294912;
    localparam [3:0] IDLE=0,RESET=1,CHOOSE=2,READ=3,FILL=4,WRITE_WAIT=5,FAILED=6;
    reg request,release_req,cpu_busy,cpu_done,cpu_error,cpu_held;
    reg [31:0] cfg_id,cfg_mode,cpu_id,cpu_tensor,cpu_raw,cpu_cycles,cpu_input;
    reg [7:0] cpu_code;
    reg ack,response_error,response_held;
    reg [7:0] response_code;
    reg [31:0] response_id,response_tensor,response_raw,response_cycles,response_input;
    (* ASYNC_REG="TRUE" *) reg req_meta,req_sync,ack_meta,ack_sync,ready_meta,ready_sync,fault_meta,fault_sync;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            request<=0;release_req<=0;cpu_busy<=0;cpu_done<=0;cpu_error<=0;cpu_held<=0;
            cfg_id<=0;cfg_mode<=0;cpu_id<=0;cpu_code<=0;cpu_tensor<=0;cpu_raw<=0;cpu_cycles<=0;cpu_input<=0;
            ack_meta<=0;ack_sync<=0;ready_meta<=0;ready_sync<=0;fault_meta<=0;fault_sync<=0;
        end else begin
            ack_meta<=ack;ack_sync<=ack_meta;ready_meta<=ddr_ready;ready_sync<=ready_meta;
            fault_meta<=fault||shared_fault;fault_sync<=fault_meta;
            if(cpu_busy&&ack_sync==request)begin
                cpu_busy<=0;cpu_done<=1;cpu_error<=response_error;cpu_held<=response_held;
                cpu_code<=response_code;cpu_id<=response_id;cpu_tensor<=response_tensor;
                cpu_raw<=response_raw;cpu_cycles<=response_cycles;cpu_input<=response_input;
            end
            if(dev_we&&!cpu_busy)begin
                if(addr_wr==8'h08&&!cpu_held)cfg_id<=wdata;
                if(addr_wr==8'h2c&&!cpu_held)cfg_mode<=wdata;
                if(addr_wr==0)begin
                    if(wdata==4)begin cpu_done<=0;cpu_error<=0;cpu_code<=0;end
                    else if(wdata==1&&cpu_held)begin cpu_done<=1;cpu_error<=1;cpu_code<=2;end
                    else if(wdata==1||wdata==2)begin
                        request<=!request;release_req<=wdata==2;cpu_busy<=1;cpu_done<=0;cpu_error<=0;cpu_code<=0;
                    end
                end
            end
        end
    end
    always @*begin
        rdata=0;
        case(addr_rd)
            8'h04:rdata={26'b0,fault_sync,ready_sync,cpu_held,cpu_error,cpu_done,cpu_busy};
            8'h08:rdata=cpu_id;
            8'h0c:rdata=0;
            8'h10:rdata=32'h03f00000;
            8'h14:rdata=TENSOR_BYTES;
            8'h18:rdata={24'b0,cpu_code};
            8'h1c:rdata=cpu_tensor;
            8'h20:rdata=0;
            8'h24:rdata=32'h03e00000;
            8'h28:rdata=cpu_raw;
            8'h2c:rdata=cfg_mode;
            8'h30:rdata=cpu_cycles;
            8'h34:rdata=cpu_input;
            8'h38:rdata=32'h53494d31; // SIM1: SPI image hardware ABI
            default:;
        endcase
    end

    reg [3:0] state;
    reg [4:0] reset_count;
    reg job_reset_n,job_ai,job_held,job_available,locked_fault,write_tensor,pool_finished;
    reg [31:0] job_id,input_read,raw_written,tensor_written,timer;
    reg [1:0] pixel_lane;
    reg [3:0] fill_count;
    reg pool_start;
    wire dma_ready,dma_busy,dma_done,dma_error,dma_fault;
    wire [3:0] dma_code;
    wire cmd_fire;
    reg cmd_valid,cmd_write;
    reg [31:0] cmd_addr;
    wire dma_rvalid,dma_rready,dma_rlast,dma_wvalid,dma_wready;
    wire [127:0] dma_rdata,dma_wdata;
    wire raw_full,raw_empty,raw_ip_read,raw_head_take;
    wire [9:0] raw_ip_level;
    wire [127:0] raw_data;
    reg raw_head;
    wire tensor_full,tensor_empty,tensor_ip_read,tensor_head_take;
    wire [8:0] tensor_ip_level;
    wire [127:0] tensor_data;
    reg tensor_head;
    wire [10:0] raw_level={1'b0,raw_ip_level}+{10'b0,raw_head};
    wire [9:0] tensor_level={1'b0,tensor_ip_level}+{9'b0,tensor_head};
    wire pool_ready,pool_valid,pool_last,pool_done,pool_error;
    wire [127:0] pool_data;
    wire [15:0] pool_beats;
    wire pixel_valid=state==READ&&dma_rvalid&&!raw_full;
    wire pixel_take=pixel_valid&&(!job_ai||pool_ready);
    wire [31:0] rgbx=dma_rdata[pixel_lane*32+:32];
    wire [23:0] rgb={rgbx[7:0],rgbx[15:8],rgbx[23:16]};
    assign active=state!=IDLE;
    assign held=job_held;
    assign available=job_available;
    assign frame_id=job_id;
    assign fault=locked_fault||dma_fault;
    assign dma_rready=pixel_take&&pixel_lane==3;
    assign dma_wvalid=state==FILL&&(write_tensor?tensor_head:raw_head);
    assign dma_wdata=write_tensor?tensor_data:raw_data;
    assign raw_head_take=dma_wvalid&&dma_wready&&!write_tensor;
    assign tensor_head_take=dma_wvalid&&dma_wready&&write_tensor;
    assign raw_ip_read=job_reset_n&&!raw_empty&&(!raw_head||raw_head_take);
    assign tensor_ip_read=job_reset_n&&!tensor_empty&&(!tensor_head||tensor_head_take);
    assign cmd_fire=cmd_valid&&dma_ready;
    always @*begin
        cmd_valid=0;cmd_write=0;cmd_addr=0;
        if(state==CHOOSE)begin
            if(job_ai&&tensor_level>=16)begin cmd_valid=1;cmd_write=1;cmd_addr=32'h07f00000+tensor_written;end
            else if(raw_level>=16)begin cmd_valid=1;cmd_write=1;cmd_addr=raw_written<<1;end
            else if(input_read<INPUT_BYTES)begin cmd_valid=1;cmd_addr=32'h07e00000+input_read;end
        end
    end
    fifo_2_ddr u_raw_fifo(.wr_clk(core_clk),.wr_rst(!job_reset_n),.wr_en(pixel_take),
        .wr_data({rgb[23:19],rgb[15:10],rgb[7:3]}),.wr_full(raw_full),.almost_full(),
        .rd_clk(core_clk),.rd_rst(!job_reset_n),.rd_en(raw_ip_read),.rd_data(raw_data),
        .rd_empty(raw_empty),.almost_empty(),.rd_water_level(raw_ip_level));
    spi_tensor_fifo u_tensor_fifo(.wr_clk(core_clk),.wr_rst(!job_reset_n),
        .wr_en(pool_valid&&!tensor_full),.wr_data(pool_data),.wr_full(tensor_full),.almost_full(),
        .rd_clk(core_clk),.rd_rst(!job_reset_n),.rd_en(tensor_ip_read),.rd_data(tensor_data),
        .rd_empty(tensor_empty),.almost_empty(),.rd_water_level(tensor_ip_level));
    rgb888_pool96_stream u_pool(.clk(core_clk),.rst_n(job_reset_n),.start(pool_start),.cancel(1'b0),
        .in_valid(pixel_valid&&job_ai),.in_ready(pool_ready),.rgb(rgb),
        .out_valid(pool_valid),.out_ready(!tensor_full),.out_data(pool_data),.out_last(pool_last),
        .done(pool_done),.error(pool_error),.out_beats(pool_beats));
    ddr_block_transfer #(.AXI_ID(4'd0),.TIMEOUT_CYCLES(65536)) u_dma(
        .core_clk(core_clk),.rst_n(rst_n),.ddr_init_done(ddr_ready),
        .cmd_valid(cmd_valid),.cmd_ready(dma_ready),.cmd_write(cmd_write),.cmd_addr(cmd_addr),.cmd_len(32'd256),
        .clear_status(1'b0),.busy(dma_busy),.done(dma_done),.error(dma_error),.error_code(dma_code),.fault(dma_fault),
        .wr_valid(dma_wvalid),.wr_ready(dma_wready),.wr_data(dma_wdata),
        .rd_valid(dma_rvalid),.rd_ready(dma_rready),.rd_data(dma_rdata),.rd_last(dma_rlast),
        .axi_awaddr(axi_awaddr),.axi_awuser_ap(axi_awap),.axi_awuser_id(axi_awid),.axi_awlen(axi_awlen),
        .axi_awvalid(axi_awvalid),.axi_awready(axi_awready),.axi_wdata(axi_wdata),.axi_wstrb(axi_wstrb),
        .axi_wready(axi_wready),.axi_wusero_id(axi_wid),.axi_wusero_last(axi_wlast),
        .axi_araddr(axi_araddr),.axi_aruser_ap(axi_arap),.axi_aruser_id(axi_arid),.axi_arlen(axi_arlen),
        .axi_arvalid(axi_arvalid),.axi_arready(axi_arready),.axi_rdata(axi_rdata),.axi_rid(axi_rid),
        .axi_rlast(axi_rlast),.axi_rvalid(axi_rvalid));
    always @(posedge core_clk or negedge rst_n)begin
        if(!rst_n)begin
            req_meta<=0;req_sync<=0;ack<=0;state<=IDLE;reset_count<=0;job_reset_n<=0;
            job_ai<=0;job_held<=0;job_available<=0;locked_fault<=0;write_tensor<=0;pool_finished<=0;
            job_id<=0;input_read<=0;raw_written<=0;tensor_written<=0;timer<=0;pixel_lane<=0;fill_count<=0;
            pool_start<=0;raw_head<=0;tensor_head<=0;
            response_error<=0;response_held<=0;response_code<=0;response_id<=0;
            response_tensor<=0;response_raw<=0;response_cycles<=0;response_input<=0;
        end else begin
            req_meta<=request;req_sync<=req_meta;pool_start<=0;
            if(!job_reset_n)begin raw_head<=0;tensor_head<=0;end
            else begin
                if(raw_ip_read)raw_head<=1;else if(raw_head_take)raw_head<=0;
                if(tensor_ip_read)tensor_head<=1;else if(tensor_head_take)tensor_head<=0;
            end
            if(pool_done)pool_finished<=1;
            if(state!=IDLE&&state!=FAILED)timer<=timer+1'b1;
            if(state!=IDLE&&state!=FAILED&&(dma_fault||shared_fault||timer>=32'd32000000||(pool_done&&pool_error)))begin
                // An uncertain native transaction is never locally reset/replayed.
                locked_fault<=1;state<=FAILED;job_available<=0;response_error<=1;response_held<=0;
                response_code<=dma_fault?{4'h8,dma_code}:8'h40;response_cycles<=timer;ack<=req_sync;
            end else case(state)
                IDLE:if(req_sync!=ack)begin
                    response_error<=0;response_code<=0;
                    if(release_req)begin
                        if(|external_hold)begin response_error<=1;response_code<=2;end
                        else begin job_held<=0;job_available<=0;response_held<=0;end
                        ack<=req_sync;
                    end else if(job_held||(|external_hold)||!ddr_ready||shared_fault||cfg_mode>1||!cfg_id)begin
                        response_error<=1;response_code<=1;ack<=req_sync;
                    end else begin
                        job_id<=cfg_id;job_ai<=cfg_mode[0];job_held<=0;job_available<=0;response_held<=0;
                        input_read<=0;raw_written<=0;tensor_written<=0;timer<=0;
                        response_id<=cfg_id;response_input<=0;response_raw<=0;response_tensor<=0;
                        job_reset_n<=0;reset_count<=0;pool_finished<=0;pixel_lane<=0;state<=RESET;
                    end
                end
                RESET:begin
                    reset_count<=reset_count+1'b1;
                    if(reset_count==15)job_reset_n<=1;
                    if(reset_count==31)begin pool_start<=job_ai;state<=CHOOSE;end
                end
                CHOOSE:begin
                    if(cmd_fire)begin
                        if(cmd_write)begin write_tensor<=job_ai&&tensor_level>=16;fill_count<=0;state<=FILL;end
                        else begin pixel_lane<=0;state<=READ;end
                    end else if(dma_ready&&input_read==INPUT_BYTES&&raw_written==RAW_BYTES&&
                        (!job_ai||(pool_finished&&tensor_written==TENSOR_BYTES)))begin
                        job_held<=1;job_available<=1;response_held<=1;response_id<=job_id;
                        response_tensor<=tensor_written;response_raw<=raw_written;response_input<=input_read;
                        response_cycles<=timer;ack<=req_sync;state<=IDLE;
                    end
                end
                READ:if(pixel_take)begin
                    pixel_lane<=pixel_lane+1'b1;
                    if(dma_rready&&dma_rlast)begin input_read<=input_read+256;state<=CHOOSE;end
                end
                FILL:if(dma_wvalid&&dma_wready)begin
                    fill_count<=fill_count+1'b1;if(fill_count==15)state<=WRITE_WAIT;
                end
                WRITE_WAIT:if(dma_done&&!dma_busy)begin
                    if(dma_error)begin locked_fault<=1;response_error<=1;response_code<=8'h80;ack<=req_sync;state<=FAILED;end
                    else begin
                        if(write_tensor)tensor_written<=tensor_written+256;else raw_written<=raw_written+256;
                        state<=CHOOSE;
                    end
                end
                default:;
            endcase
        end
    end
endmodule
`default_nettype wire
