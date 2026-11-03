`default_nettype none
// CPU->DDR command mailbox, DDR->PCIe arm handshake and PCIe->DDR completion.
// Busy/locked protects the raw slot until all pixels and the DMA have drained.
module video_present_control #(
    parameter integer WIDTH=1920,HEIGHT=1080
)(
    input wire clk,core_clk,pcie_clk,rst_n,pcie_rst_n,pcie_link_up,ddr_ready,
    input wire dev_we,
    input wire [7:0] addr_wr,addr_rd,
    input wire [31:0] wdata,
    output reg [31:0] rdata,
    input wire [4:0] frame_available,frame_held,
    input wire [159:0] frame_ids,
    input wire [2:0] write_slot,
    input wire write_active,reader_busy,reader_done,
    input wire pixel_valid,pixel_ready,dma_busy,stream_empty,
    output wire [4:0] reader_frames,protect_mask,
    output reg [4:0] active_count,
    output reg [1023:0] active_boxes
);
    localparam [2:0] IDLE=0,VALIDATE=1,ARM=2,START=3,RUN=4,LOCKED=5;
    localparam [31:0] WORDS=WIDTH*HEIGHT/8;
    reg [31:0] cfg_id;
    reg [2:0] cfg_slot;
    reg [4:0] cfg_count;
    reg [3:0] cfg_index;
    reg [31:0] cfg_xy0,cfg_xy1;
    reg [1023:0] cfg_boxes;
    reg [15:0] cfg_written;
    reg request,cpu_busy,cpu_done,cpu_error;
    reg [7:0] cpu_code;
    reg ack,response_error;
    reg [7:0] response_code;
    reg [31:0] core_id;
    reg [2:0] core_slot,state;
    reg core_hold,core_locked,read_complete,pc_request;
    reg pc_arm,pc_done,pc_fault,pc_active,saw_dma;
    reg [31:0] pc_words;
    (* ASYNC_REG="TRUE" *) reg req_meta,req_sync,ack_meta,ack_sync;
    (* ASYNC_REG="TRUE" *) reg ready_meta,ready_sync,lock_meta,lock_sync;
    (* ASYNC_REG="TRUE" *) reg prepared_meta,prepared_sync;
    (* ASYNC_REG="TRUE" *) reg link_meta,link_sync,arm_meta,arm_sync,done_meta,done_sync,fault_meta,fault_sync;
    (* ASYNC_REG="TRUE" *) reg pc_req_meta,pc_req_sync;
    wire pc_available=pcie_rst_n&&pcie_link_up;
    // RUN means the PCIe arm acknowledgement and DDR reader start both arrived.
    // Bit 5 remains the sticky fault lock; bit 6 grants RK permission to start DMA.
    wire core_prepared=state==RUN && core_hold && !core_locked;
    wire [15:0] required=16'hffff>>(16-cfg_count);
    assign reader_frames=state==START ? (5'b1<<core_slot):5'b0;
    assign protect_mask=core_hold ? (5'b1<<core_slot):5'b0;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            cfg_id<=0;cfg_slot<=0;cfg_count<=0;cfg_index<=0;cfg_xy0<=0;cfg_xy1<=0;
            cfg_boxes<=0;cfg_written<=0;request<=0;cpu_busy<=0;cpu_done<=0;cpu_error<=0;cpu_code<=0;
            ack_meta<=0;ack_sync<=0;ready_meta<=0;ready_sync<=0;lock_meta<=0;lock_sync<=0;
            prepared_meta<=0;prepared_sync<=0;
        end else begin
            ack_meta<=ack;ack_sync<=ack_meta;ready_meta<=pc_available;ready_sync<=ready_meta;
            lock_meta<=core_locked;lock_sync<=lock_meta;
            prepared_meta<=core_prepared;prepared_sync<=prepared_meta;
            if(cpu_busy && ack_sync==request)begin
                cpu_busy<=0;cpu_done<=1;cpu_error<=response_error;cpu_code<=response_code;
            end
            if(dev_we && !cpu_busy && !lock_sync)case(addr_wr)
                8'h08:cfg_id<=wdata;
                8'h0c:cfg_slot<=wdata<5 ? wdata[2:0]:3'd7;
                8'h10:begin cfg_count<=wdata<=16 ? wdata[4:0]:5'd31;cfg_written<=0;end
                8'h14:cfg_index<=wdata[3:0];
                8'h18:cfg_xy0<=wdata;
                8'h1c:cfg_xy1<=wdata;
                8'h20:begin
                    cfg_boxes[cfg_index*64+:64]<={4'b0,wdata[15:0],cfg_xy1[26:16],cfg_xy1[10:0],cfg_xy0[26:16],cfg_xy0[10:0]};
                    cfg_written[cfg_index]<=cfg_xy0[15:11]==0 && cfg_xy0[31:27]==0 && cfg_xy1[15:11]==0 && cfg_xy1[31:27]==0 &&
                        cfg_xy0[10:0]<=cfg_xy1[10:0] && cfg_xy0[26:16]<=cfg_xy1[26:16] &&
                        cfg_xy1[10:0]<WIDTH && cfg_xy1[26:16]<HEIGHT;
                end
                8'h00:begin
                    if(wdata==4)begin cpu_done<=0;cpu_error<=0;cpu_code<=0;end
                    else if(wdata==1)begin
                        if(!ready_sync)begin cpu_done<=1;cpu_error<=1;cpu_code<=1;end
                        else if(cfg_slot>=5 || cfg_count>16 || (cfg_written&required)!=required)begin cpu_done<=1;cpu_error<=1;cpu_code<=2;end
                        else begin request<=!request;cpu_busy<=1;cpu_done<=0;cpu_error<=0;cpu_code<=0;end
                    end
                end
                default:;
            endcase
        end
    end
    always @*begin
        rdata=0;
        case(addr_rd)
            8'h04:rdata={25'b0,prepared_sync,lock_sync,1'b1,ready_sync,cpu_error,cpu_done,cpu_busy};
            8'h08:rdata=cfg_id;
            8'h0c:rdata={29'b0,cfg_slot};
            8'h10:rdata={27'b0,cfg_count};
            8'h24:rdata={24'b0,cpu_code};
            8'h28:rdata=core_id;
            8'h2c:rdata=WORDS;
            8'h34:rdata=16;
            default:;
        endcase
    end
    always @(posedge core_clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=IDLE;req_meta<=0;req_sync<=0;ack<=0;core_id<=0;core_slot<=0;
            active_boxes<=0;active_count<=0;core_hold<=0;core_locked<=0;pc_request<=0;
            link_meta<=0;link_sync<=0;arm_meta<=0;arm_sync<=0;done_meta<=0;done_sync<=0;
            fault_meta<=0;fault_sync<=0;response_error<=0;response_code<=0;read_complete<=0;
        end else begin
            req_meta<=request;req_sync<=req_meta;link_meta<=pc_available;link_sync<=link_meta;
            arm_meta<=pc_arm;arm_sync<=arm_meta;done_meta<=pc_done;done_sync<=done_meta;
            fault_meta<=pc_fault;fault_sync<=fault_meta;
            case(state)
                IDLE:if(req_sync!=ack)begin
                    core_id<=cfg_id;core_slot<=cfg_slot;active_count<=cfg_count;active_boxes<=cfg_boxes;
                    read_complete<=0;state<=VALIDATE;
                end
                VALIDATE:begin
                    if(!link_sync || !ddr_ready)begin response_error<=1;response_code<=1;ack<=req_sync;state<=IDLE;end
                    else if(!frame_available[core_slot] || !frame_held[core_slot] ||
                        (write_active&&write_slot==core_slot) || frame_ids[core_slot*32+:32]!=core_id)begin
                        response_error<=1;response_code<=3;ack<=req_sync;state<=IDLE;
                    end else begin core_hold<=1;pc_request<=!pc_request;state<=ARM;end
                end
                ARM:if(arm_sync==pc_request)state<=START;
                START:if(reader_busy)state<=RUN;
                RUN:begin
                    if(reader_done)read_complete<=1;
                    if((read_complete||reader_done) && done_sync==pc_request)begin
                        core_hold<=0;response_error<=0;response_code<=0;ack<=req_sync;state<=IDLE;
                    end
                end
                default:;
            endcase
            if((state==ARM || state==START || state==RUN) && (!link_sync || fault_sync))begin
                core_locked<=1;response_error<=1;response_code<=fault_sync?8'd5:8'd4;
                ack<=req_sync;state<=LOCKED; // Preserve the slot until common reset.
            end
        end
    end
    wire pc_reset_n=rst_n&&pcie_rst_n;
    always @(posedge pcie_clk or negedge pc_reset_n)begin
        if(!pc_reset_n)begin
            pc_req_meta<=0;pc_req_sync<=0;pc_arm<=0;pc_done<=0;pc_active<=0;pc_fault<=0;pc_words<=0;saw_dma<=0;
        end else begin
            pc_req_meta<=pc_request;pc_req_sync<=pc_req_meta;
            if(!pc_active && pc_req_sync!=pc_arm)begin
                pc_arm<=pc_req_sync;pc_active<=1;pc_words<=0;saw_dma<=0;
            end
            if(pc_active)begin
                if(dma_busy)saw_dma<=1;
                if(pixel_ready && !pixel_valid)pc_fault<=1;
                if(pixel_ready && pixel_valid)begin
                    if(pc_words<WORDS)pc_words<=pc_words+1;
                    else pc_fault<=1;
                end
                if(pc_words==WORDS && saw_dma && !dma_busy && stream_empty)begin
                    pc_done<=pc_arm;pc_active<=0;
                end
            end
        end
    end
endmodule
`default_nettype wire
