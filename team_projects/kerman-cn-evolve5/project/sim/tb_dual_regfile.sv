`timescale 1ns/1ps
module tb_dual_regfile;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,we=0,we2=0;
    reg [4:0] rs1=0,rs2=0,rs3=0,rs4=0,rd=0,rd2=0;
    reg [31:0] wd=0,wd2=0,rng=32'hd0a11021;
    wire [31:0] a,b,c,d,sa,sb,sc,sd;
    rv32_regfile #(.DUAL_ENABLE(1)) dual(.clk(clk),.rst(rst),.rs1(rs1),.rs2(rs2),.rs3(rs3),.rs4(rs4),
        .rdata1(a),.rdata2(b),.rdata3(c),.rdata4(d),.we(we),.rd(rd),.wdata(wd),.we2(we2),.rd2(rd2),.wdata2(wd2));
    rv32_regfile #(.DUAL_ENABLE(0)) scalar(.clk(clk),.rst(rst),.rs1(rs1),.rs2(rs2),.rs3(rs3),.rs4(rs4),
        .rdata1(sa),.rdata2(sb),.rdata3(sc),.rdata4(sd),.we(we),.rd(rd),.wdata(wd),.we2(we2),.rd2(rd2),.wdata2(wd2));
    reg [31:0] model[0:31],single[0:31];integer n,k;
    function automatic [31:0] value(input [4:0] address,input bit two);
        if(address==0)value=0;
        else if(two && we2 && address==rd2)value=wd2;
        else if(we && address==rd)value=wd;
        else value=two?model[address]:single[address];
    endfunction
    task check;
        if({a,b,c,d,sa,sb,sc,sd}!=={value(rs1,1),value(rs2,1),value(rs3,1),value(rs4,1),value(rs1,0),value(rs2,0),32'b0,32'b0})
            $fatal(1,"Regfile read/bypass mismatch vector=%0d",n);
    endtask
    initial begin
        for(k=0;k<32;k=k+1)begin model[k]=0;single[k]=0;end
        repeat(3)@(posedge clk);
        for(n=0;n<6000;n=n+1)begin
            @(negedge clk);rng=rng*1664525+1013904223;
            rst=(n%997==0);we=!rst&&rng[0];we2=!rst&&rng[4];rd=rng[9:5];rd2=n%3==0?rd:rng[14:10];
            rs1=n%4==0?rd:rng[19:15];rs2=n%4==1?rd2:rng[24:20];rs3=rd;rs4=rd2;
            wd=rng^32'ha51b9077;wd2=~rng;
            #1;check();
            @(posedge clk);
            if(rst)for(k=0;k<32;k=k+1)begin model[k]=0;single[k]=0;end
            else begin
                if(we && rd!=0)begin model[rd]=wd;single[rd]=wd;end
                if(we2 && rd2!=0)model[rd2]=wd2;
            end
            #1;check();
        end
        @(negedge clk);we=0;we2=0;
        for(k=0;k<32;k=k+1)begin rs1=k;rs2=k;rs3=k;rs4=k;#1;check();end
        $display("DUAL_REGFILE_PASS vectors=6000 four_read_two_write x0 bypass_waw reset scalar_compat");$finish;
    end
endmodule
