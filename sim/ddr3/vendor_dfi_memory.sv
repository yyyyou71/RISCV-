`timescale 1ns/1ps
// Test-only PHY substitute. The original encrypted vendor memory controller
// still performs command scheduling, address decoding, and byte-mask conversion.
// This model checks that address decoding matches the documented BANK/ROW/COL
// mapping, and applies the controller's DFI masks (1 = suppress byte write).
// It does not model PHY calibration, pins, or physical timing.
module vendor_dfi_memory(
    input wire clk,rst_n,
    input wire [59:0] address,
    input wire [11:0] bank,
    input wire [3:0] cs_n,ras_n,cas_n,we_n,
    input wire [127:0] wrdata,
    input wire [3:0] wrdata_en,
    input wire [15:0] wrdata_mask,
    output reg [127:0] rddata=0,
    output reg rddata_valid=0
);
    reg [127:0] storage[int unsigned];
    reg [14:0] row[0:7];
    reg [7:0] open_bank=0;
    reg [27:0] writes[0:1023],reads[0:1023];
    integer due[0:1023];
    integer write_in=0,write_out=0,read_in=0,read_out=0,cycle=0;
    integer phase,b,byte_lane;
    reg [14:0] ca;
    reg [27:0] location;
    always @(posedge clk) begin
        if(!rst_n)begin
            open_bank=0;write_in=0;write_out=0;read_in=0;read_out=0;cycle=0;
            rddata<=0;rddata_valid<=0;
        end else begin
            cycle=cycle+1;
            rddata_valid<=0;
            for(phase=0;phase<4;phase=phase+1)begin
                b=bank[phase*3+:3];ca=address[phase*15+:15];
                if(!cs_n[phase])case({ras_n[phase],cas_n[phase],we_n[phase]})
                    3'b011:begin row[b]=ca;open_bank[b]=1;end // ACT
                    3'b010:begin // PRE / PRE ALL
                        if(ca[10])open_bank=0;else open_bank[b]=0;
                    end
                    3'b100,3'b101:begin // WRITE / READ, burst length 8
                        if(!open_bank[b])$fatal(1,"DFI access without open row bank=%0d",b);
                        location={b[2:0],row[b],ca[9:0]};
                        if(location[2:0]!=0)$fatal(1,"unaligned DFI BL8 address %h",location);
                        $display("DFI %s address=%h",we_n[phase]?"READ":"WRITE",location);
                        if(we_n[phase])begin
                            reads[read_in%1024]=location;
                            due[read_in%1024]=cycle+8;read_in=read_in+1;
                        end else begin
                            writes[write_in%1024]=location;write_in=write_in+1;
                        end
                        if(ca[10])open_bank[b]=0;
                    end
                    default:begin end
                endcase
            end
            if(|wrdata_en)begin
                if(write_out==write_in)$fatal(1,"DFI write data before WRITE command");
                if(wrdata_en!=4'hf)$fatal(1,"unsupported DFI write enable %h",wrdata_en);
                location=writes[write_out%1024];write_out=write_out+1;
                if(!storage.exists(location))storage[location]=0;
                for(byte_lane=0;byte_lane<16;byte_lane=byte_lane+1)
                    if(!wrdata_mask[byte_lane])storage[location][byte_lane*8+:8]=wrdata[byte_lane*8+:8];
            end
            if(read_out!=read_in && due[read_out%1024]<=cycle)begin
                location=reads[read_out%1024];read_out=read_out+1;
                if(!storage.exists(location))$fatal(1,"DFI read of unwritten address %h",location);
                rddata<=storage[location];rddata_valid<=1;
            end
        end
    end
endmodule
