`default_nettype none
// One CPU-controlled frame lease, synchronized request/response toggles.
// Configuration/result buses stay stable throughout each handshake.
module frame_mailbox (
    input wire clk,core_clk,rst_n,
    input wire dev_we,
    input wire [31:0] dev_addr_wr,dev_addr_rd,dev_wdata,
    output reg [31:0] read_data,
    input wire [4:0] available,
    input wire [159:0] frame_ids,
    input wire [2:0] wr_slot,
    input wire wr_active,ddr_ready,arb_fault,
    input wire [31:0] video_shape,video_period,
    output wire [4:0] hold_mask
);
    (* ASYNC_REG="TRUE" *) reg [1:0] cpu_reset,core_reset;
    always @(posedge clk or negedge rst_n) if(!rst_n)cpu_reset<=0;else cpu_reset<={cpu_reset[0],1'b1};
    always @(posedge core_clk or negedge rst_n) if(!rst_n)core_reset<=0;else core_reset<={core_reset[0],1'b1};
    reg req,command_release,busy,done,error,held;
    reg [2:0] cpu_slot;
    reg [31:0] cpu_id;
    reg ack,core_held,response_error;
    reg [2:0] core_slot;
    reg [31:0] core_id;
    (* ASYNC_REG="TRUE" *) reg req_meta,req_sync,ack_meta,ack_sync;
    (* ASYNC_REG="TRUE" *) reg ready_meta,ready_sync,fault_meta,fault_sync;
    reg searching,scan_found;
    reg [4:0] reserved;
    reg [2:0] scan_index,scan_slot;
    reg [31:0] scan_id;
    wire pending_acquire=req_sync!=ack && !command_release && !core_held && ddr_ready && !arb_fault;
    wire [4:0] eligible=available & ~(wr_active ? (5'b1<<wr_slot):5'b0);
    wire [31:0] indexed_id=frame_ids[scan_index*32 +:32];
    wire scan_wins=reserved[scan_index] && (!scan_found || $signed(indexed_id-scan_id)>0);
    // Reserve the snapshot while selecting one slot per cycle. Protection does
    // not depend on a chain of five 32-bit frame-id comparisons. Including live
    // available closes the first request/SOF race; reserved survives a reader
    // clearing available during the scan. Stage-to-stage ownership has no gap.
    assign hold_mask=(core_held ? (5'b1<<core_slot):5'b0) |
                     (pending_acquire ? (available|reserved):5'b0);
    always @(posedge core_clk or negedge core_reset[1]) begin
        if(!core_reset[1]) begin
            req_meta<=0;req_sync<=0;ack<=0;core_held<=0;core_slot<=0;core_id<=0;response_error<=0;
            searching<=0;reserved<=0;scan_index<=0;scan_found<=0;scan_slot<=0;scan_id<=0;
        end else begin
            req_meta<=req;req_sync<=req_meta;
            if(searching)begin
                if(!ddr_ready || arb_fault)begin
                    response_error<=1;ack<=req_sync;searching<=0;reserved<=0;
                end else begin
                    if(scan_wins)begin scan_found<=1;scan_slot<=scan_index;scan_id<=indexed_id;end
                    if(scan_index==4)begin
                        response_error<=!(scan_found||scan_wins);
                        core_held<=scan_found||scan_wins;
                        core_slot<=scan_wins ? scan_index:scan_slot;
                        core_id<=scan_wins ? indexed_id:scan_id;
                        ack<=req_sync;searching<=0;reserved<=0;
                    end else scan_index<=scan_index+1'b1;
                end
            end else if(req_sync!=ack) begin
                response_error<=0;
                if(command_release)begin core_held<=0;ack<=req_sync;end
                else if(core_held)ack<=req_sync;
                else if(!ddr_ready||arb_fault)begin response_error<=1;ack<=req_sync;end
                else begin
                    searching<=1;reserved<=eligible;scan_index<=0;
                    scan_found<=0;scan_slot<=0;scan_id<=0;
                end
            end
        end
    end
    always @(posedge clk or negedge cpu_reset[1]) begin
        if(!cpu_reset[1]) begin
            req<=0;command_release<=0;busy<=0;done<=0;error<=0;held<=0;cpu_slot<=0;cpu_id<=0;
            ack_meta<=0;ack_sync<=0;ready_meta<=0;ready_sync<=0;fault_meta<=0;fault_sync<=0;
        end else begin
            ack_meta<=ack;ack_sync<=ack_meta;
            ready_meta<=ddr_ready;ready_sync<=ready_meta;fault_meta<=arb_fault;fault_sync<=fault_meta;
            if(busy && ack_sync==req) begin
                busy<=0;done<=1;error<=response_error;held<=core_held;cpu_slot<=core_slot;cpu_id<=core_id;
            end
            if(dev_we && dev_addr_wr==32'h30600 && !busy) begin
                if(dev_wdata==1 || dev_wdata==2) begin
                    command_release<=dev_wdata==2;req<=!req;busy<=1;done<=0;error<=0;
                end else if(dev_wdata==4) begin done<=0;error<=0;end
            end
        end
    end
    always @(*) begin
        read_data=0;
        case(dev_addr_rd)
            32'h30604: read_data={26'b0,fault_sync,ready_sync,error,done,held,busy};
            32'h30608: read_data={29'b0,cpu_slot};
            32'h3060c: read_data=cpu_id;
            32'h30610: read_data={7'b0,cpu_slot,22'b0}; // native address; legacy video slots
            32'h30614: read_data=256; // native units per video burst (legacy layout)
            32'h30618: read_data=4147200;
            32'h3061c: read_data=video_shape;
            32'h30620: read_data=video_period;
            default: read_data=0;
        endcase
    end
endmodule
`default_nettype wire
