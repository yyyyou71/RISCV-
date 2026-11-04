`timescale 1ns/1ps
module TB_parallel_mac;
`ifdef GATE_NETLIST
    GTP_GRS GRS_INST(.GRS_N(1'b1));
`endif
    reg clk=0,rst_n=0,load_valid=0,load_weight=0,start_valid=0,compute_enable=0,out_ready=0;
    always #3.8095 clk=~clk;
    reg [1:0] load_lane=0;
    reg [3:0] load_tap=0,tap_count=1;
    reg [255:0] load_data=0,initial_sums=0;
    wire load_ready,start_ready,busy,error,out_valid,issue_valid;
    wire [255:0] out_sums;
`ifdef GATE_NETLIST
    conv_mac_tile dut(
`else
    conv_mac_tile #(.ACT_WIDTH(16),.REDUCE_PAIRS(2)) dut(
`endif
        .clk(clk),.rst_n(rst_n),.load_valid(load_valid),.load_ready(load_ready),
        .load_weight(load_weight),.load_lane(load_lane),.load_tap(load_tap),.load_data(load_data),
        .start_valid(start_valid),.start_ready(start_ready),.tap_count(tap_count),.initial_sums(initial_sums),
        .compute_enable(compute_enable),.busy(busy),.error(error),.out_valid(out_valid),
        .out_ready(out_ready),.out_sums(out_sums),.issue_valid(issue_valid));
    function signed [15:0] activation;input integer n,t,k;begin
        case(n%4)
        0:activation=-32768;1:activation=32767;
        default:activation=16'((n*997+t*271+k*7919)^32'ha75a);
        endcase
    end endfunction
    function signed [7:0] weight;input integer n,l,t,k;begin
        case(n%4)
        0:weight=-128;1:weight=l%2?127:-128;
        default:weight=8'(n*37+l*73+t*29+k*19);
        endcase
    end endfunction
    task put;begin
        load_valid=1;@(negedge clk);while(!load_ready)@(negedge clk);load_valid=0;
    end endtask
    reg signed [63:0] expected[0:3];
    reg signed [31:0] term;
    reg [255:0] held;
    integer n,t,k,l,cycles,issues;
    always @(posedge clk)if(rst_n&&issue_valid)issues=issues+1;
    initial begin
        issues=0;repeat(8)@(negedge clk);rst_n=1;
        for(n=0;n<16;n=n+1)begin
            tap_count=n%2?9:1;
            for(l=0;l<4;l=l+1)begin
                expected[l]=64'sh123456789+l*1000-n*77;
                initial_sums[l*64+:64]=expected[l];
                for(t=0;t<tap_count;t=t+1)for(k=0;k<16;k=k+1)begin
                    term=activation(n,t,k)*weight(n,l,t,k);expected[l]=expected[l]+term;
                end
            end
            for(t=0;t<tap_count;t=t+1)begin
                load_weight=0;load_tap=4'(t);
                for(k=0;k<16;k=k+1)load_data[k*16+:16]=activation(n,t,k);
                put();
                for(l=0;l<4;l=l+1)begin
                    load_weight=1;load_lane=2'(l);load_data=0;
                    for(k=0;k<16;k=k+1)load_data[k*8+:8]=weight(n,l,t,k);
                    put();
                end
            end
            issues=0;start_valid=1;@(negedge clk);start_valid=0;
            cycles=0;
            while(!out_valid)begin
                compute_enable=(cycles%5!=1&&cycles%7!=3);
                @(negedge clk);cycles=cycles+1;
                if(cycles>500)$fatal(1,"parallel MAC timeout");
            end
            if(error||issues!=tap_count*4)$fatal(1,"parallel MAC status/issues %0d",issues);
            for(l=0;l<4;l=l+1)if(out_sums[l*64+:64]!==expected[l])
                $fatal(1,"parallel MAC mismatch case=%0d lane=%0d got=%h expected=%h",n,l,out_sums[l*64+:64],expected[l]);
            held=out_sums;repeat(5)begin @(negedge clk);if(!out_valid||out_sums!==held)$fatal(1,"output not held");end
            out_ready=1;@(negedge clk);out_ready=0;compute_enable=0;
            if(!start_ready)$fatal(1,"result not consumed");
        end
        $display("PARALLEL_MAC_PASS cases=16 taps=1,9 signed_extremes=1 stalls=1");$finish;
    end
    initial begin #1000000;$fatal(1,"parallel MAC global timeout");end
endmodule
