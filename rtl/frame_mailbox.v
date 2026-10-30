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
    reg found;
    reg [2:0] candidate;
    reg [31:0] candidate_id;
    integer i;
    always @(*) begin
        found=0;candidate=0;candidate_id=0;
        for(i=0;i<5;i=i+1) if(available[i] && !(wr_active && wr_slot==i)) begin
            if(!found || $signed(frame_ids[i*32 +:32]-candidate_id)>0) begin
                found=1;candidate=i[2:0];candidate_id=frame_ids[i*32 +:32];
            end
        end
    end
    wire acquiring=req_sync!=ack && !command_release && !core_held && found && ddr_ready && !arb_fault;
    // Provisional protection closes the acquire/SOF race on the same core edge.
    assign hold_mask=(core_held ? (5'b1<<core_slot):5'b0) |
                     (acquiring ? (5'b1<<candidate):5'b0);
    always @(posedge core_clk or negedge core_reset[1]) begin
        if(!core_reset[1]) begin
            req_meta<=0;req_sync<=0;ack<=0;core_held<=0;core_slot<=0;core_id<=0;response_error<=0;
        end else begin
            req_meta<=req;req_sync<=req_meta;
            if(req_sync!=ack) begin
                response_error<=0;
                if(command_release) core_held<=0;
                else if(!core_held) begin
                    if(acquiring) begin core_held<=1;core_slot<=candidate;core_id<=candidate_id;end
                    else response_error<=1;
                end
                ack<=req_sync;
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
