`timescale 1ns/1ps
module TB_rk_iic;
    reg clk=0, rst_n=0, scl=1, sda_low=0;
    tri1 sda;
    assign sda = sda_low ? 1'b0 : 1'bz;
    always #20 clk=~clk; // 25 MHz
    wire [31:0] param_data;
    wire param_update, uplink_ready;
    reg [7:0] uplink_data=0;
    reg uplink_valid=0;
    reg [7:0] value;
    integer updates=0;
    always @(posedge clk) if(rst_n && param_update) updates=updates+1;
    rk_iic_adapter dut(.clk(clk), .rst_n(rst_n), .iic_scl(scl), .iic_sda(sda),
        .param_data(param_data), .param_update(param_update),
        .uplink_data(uplink_data), .uplink_valid(uplink_valid), .uplink_ready(uplink_ready));

    task start_bus; begin
        scl=0; sda_low=0; #2500; scl=1; #2500; sda_low=1; #2500; scl=0; #2500;
    end endtask
    task stop_bus; begin
        scl=0; sda_low=1; #2500; scl=1; #2500; sda_low=0; #5000;
    end endtask
    task write_byte; input [7:0] data; input expect_ack; integer i; begin
        for(i=7;i>=0;i=i-1) begin
            scl=0; sda_low=!data[i]; #2500; scl=1; #5000; scl=0; #2500;
        end
        sda_low=0; #2500; scl=1; #2500;
        if(sda !== !expect_ack) $fatal(1, "ACK mismatch byte=%h sda=%b",data,sda);
        #2500; scl=0; #2500;
    end endtask
    task read_byte; output [7:0] data; integer i; begin
        sda_low=0;
        for(i=7;i>=0;i=i-1) begin
            #2500; scl=1; #2500; data[i]=sda; #2500; scl=0; #2500;
        end
        // NACK the final byte.
        sda_low=0; #2500; scl=1; #5000; scl=0; #2500;
    end endtask
    task write_reg; input [7:0] addr,data; begin
        start_bus; write_byte(8'hcc,1); write_byte(addr,1); write_byte(data,1); stop_bus;
    end endtask
    task read_reg; input [7:0] addr; output [7:0] data; begin
        start_bus; write_byte(8'hcc,1); write_byte(addr,1);
        start_bus; write_byte(8'hcd,1); read_byte(data); stop_bus;
    end endtask
    initial begin
        #1000; @(negedge clk); rst_n=1; #10000;
        start_bus; write_byte(8'hca,0); stop_bus;
        write_reg(8'h00,8'h5a); read_reg(8'h00,value);
        if(value!==8'h5a) $fatal(1,"scratch read failed: %h",value);
        write_reg(8'h10,8'h78); write_reg(8'h11,8'h56);
        write_reg(8'h12,8'h34); write_reg(8'h13,8'h12);
        if(param_data!==0) $fatal(1,"parameter changed before commit");
        write_reg(8'h14,1);
        if(param_data!==32'h12345678 || updates!=1) $fatal(1,"commit failed");
        read_reg(8'h15,value); if(value!==1) $fatal(1,"sequence failed: read=%h stored=%h pointer=%h",value,dut.u_regs.commit_seq,dut.reg_addr);
        @(negedge clk); uplink_data=8'ha5; uplink_valid=1;
        @(negedge clk); uplink_valid=0;
        if(uplink_ready!==0) $fatal(1,"mailbox not full");
        read_reg(8'h20,value); if(value!==1) $fatal(1,"count failed");
        read_reg(8'h21,value); if(value!==8'ha5) $fatal(1,"mailbox failed");
        read_reg(8'h21,value); if(value!==8'ha5) $fatal(1,"read consumed mailbox");
        write_reg(8'h22,1);
        if(uplink_ready!==1) $fatal(1,"mailbox acknowledgment failed");
        $display("PASS: address NACK, repeated START, scratch, atomic commit, uplink mailbox");
        $finish;
    end
    initial begin #10000000; $fatal(1,"timeout"); end
endmodule
