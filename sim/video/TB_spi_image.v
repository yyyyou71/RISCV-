`timescale 1ns/1ps
module TB_spi_image;
    reg clk=0,core_clk=0,rst_n=0;
    always #20 clk=~clk;
    always #4 core_clk=~core_clk;
    reg we=0;reg [7:0] wa=0,ra=4;reg [31:0] wd=0;
    wire [31:0] rd,id;wire active,held,available,fault;
    reg [4:0] external_hold=0;
    wire [27:0] aw,ar;wire av,rv,ap,rp;
    wire [3:0] al,rl,aid,rid;
    wire [127:0] wdata;wire [15:0] strb;
    integer cycles=0,wb=0,rb=0,raw_words=0,tensor_words=0,read_words=0;
    reg writing=0,reading=0;reg [27:0] waddr=0,raddr=0;
    wire awready=!writing&&cycles%7!=0;
    wire arready=!reading&&cycles%5!=0;
    wire wready=writing&&cycles%11<8;
    wire rvalid=reading&&cycles%9<7;
    wire wlast=wready&&wb==15;
    wire rlast=rvalid&&rb==15;
    reg [127:0] rdata;
    integer lane,idx;
    spi_image_capture dut(.clk(clk),.core_clk(core_clk),.rst_n(rst_n),.ddr_ready(1'b1),.shared_fault(1'b0),
        .external_hold(external_hold),.dev_we(we),.addr_wr(wa),.addr_rd(ra),.wdata(wd),.rdata(rd),
        .active(active),.held(held),.available(available),.frame_id(id),.fault(fault),
        .axi_awaddr(aw),.axi_araddr(ar),.axi_awvalid(av),.axi_arvalid(rv),.axi_awap(ap),.axi_arap(rp),
        .axi_awlen(al),.axi_arlen(rl),.axi_awid(aid),.axi_arid(rid),
        .axi_awready(awready),.axi_arready(arready),.axi_wready(wready),.axi_wlast(wlast),.axi_wid(4'd0),
        .axi_rvalid(rvalid),.axi_rlast(rlast),.axi_rid(4'd0),.axi_wdata(wdata),.axi_wstrb(strb),.axi_rdata(rdata));
    function [23:0] pixel;input integer x,y;begin
        pixel={8'((x*17+y*29+(x^y)*3)&255),8'((x*7+y*53+(x*y)%251)&255),8'((x*11+y*19)&255)};
    end endfunction
    function [7:0] average;input integer sum;integer q,r;begin
        q=sum/12;r=sum%12;average=8'(q+(r>6||(r==6&&(q%2))));
    end endfunction
    function [127:0] tensor_expected;input integer word_index;
        integer x,y,xx,yy,sr,sg,sb;reg [23:0] p;begin
            tensor_expected=0;
            if(word_index%2==0)begin
                x=(word_index/2)%96;y=(word_index/2)/96;sr=0;sg=0;sb=0;
                for(yy=(y*216)/96;yy<((y+1)*216+95)/96;yy=yy+1)
                    for(xx=x*4;xx<(x+1)*4;xx=xx+1)begin p=pixel(xx,yy);sr=sr+p[23:16];sg=sg+p[15:8];sb=sb+p[7:0];end
                tensor_expected={80'b0,8'b0,average(sb),8'b0,average(sg),8'b0,average(sr)};
            end
        end
    endfunction
    reg [127:0] expected;reg [23:0] p;
    integer n,k;reg [23:0] rpixel;
    always @*begin
        rdata=0;
        for(k=0;k<4;k=k+1)begin
            n=((raddr-28'h3f00000)*2+rb*16)/4+k;
            rpixel=pixel(n%384,n/384);
            rdata[k*32+:32]={8'b0,rpixel[7:0],rpixel[15:8],rpixel[23:16]};
        end
    end
    always @(posedge core_clk)if(rst_n)begin
        cycles<=cycles+1;
        if(av&&awready)begin
            if(al!=15||aid!=0)$fatal(1,"write burst metadata");writing<=1;waddr<=aw;wb<=0;
        end
        if(rv&&arready)begin
            if(rl!=15||rid!=0||ar!=28'h3f00000+read_words*8)$fatal(1,"input read address/count");
            reading<=1;raddr<=ar;rb<=0;
        end
        if(rvalid)begin read_words<=read_words+1;if(rlast)begin reading<=0;rb<=0;end else rb<=rb+1;end
        if(wready)begin
            if(strb!=16'hffff)$fatal(1,"byte enables");
            if(waddr>=28'h3f80000)begin
                idx=(waddr-28'h3f80000)/8+wb;expected=tensor_expected(idx);
                if(idx!=tensor_words)$fatal(1,"tensor not contiguous");tensor_words<=tensor_words+1;
            end else begin
                idx=(waddr/256)*16+wb;
                if(waddr%256!=0||idx!=raw_words)$fatal(1,"raw legacy slot stride");
                for(lane=0;lane<8;lane=lane+1)begin p=pixel((idx*8+lane)%384,(idx*8+lane)/384);expected[lane*16+:16]={p[23:19],p[15:10],p[7:3]};end
                raw_words<=raw_words+1;
            end
            if(wdata!==expected)$fatal(1,"pixel mismatch at native %h word %0d got=%h expected=%h",waddr,idx,wdata,expected);
            if(wlast)begin writing<=0;wb<=0;end else wb<=wb+1;
        end
        if(fault)$fatal(1,"capture fault state=%0d code=%0d",dut.state,dut.response_code);
        if(available&&(raw_words!=10368||read_words!=20736))$fatal(1,"early frame completion");
    end
    task write_reg;input [7:0] a;input [31:0] v;begin
        @(negedge clk);wa=a;wd=v;we=1;@(negedge clk);we=0;
    end endtask
    task wait_done;begin
        ra=4;#1;while(!rd[1])@(negedge clk);
    end endtask
    integer mode;
    initial begin
        repeat(8)@(negedge clk);rst_n=1;repeat(8)@(negedge clk);
        for(mode=0;mode<2;mode=mode+1)begin
            write_reg(8'h08,100+mode);write_reg(8'h2c,mode);write_reg(0,1);wait_done();
            if((rd&63)!=26||!held||!available||id!=100+mode||raw_words!=10368||tensor_words!=(mode?18432:0))
                $fatal(1,"invalid final status mode=%0d status=%h raw=%0d tensor=%0d",mode,rd,raw_words,tensor_words);
            write_reg(0,1);wait_done();if(!rd[2]||!held)$fatal(1,"overwrote held input");
            external_hold=1;write_reg(0,2);wait_done();if(!rd[2]||!held)$fatal(1,"released PCIe-owned frame");
            external_hold=0;write_reg(0,2);wait_done();if(rd[3]||held||available)$fatal(1,"release failed");
            $display("PASS SPI image mode=%0d: 82944 pixels, raw=%0d words, tensor=%0d words, stalls + lease protection",mode,raw_words,tensor_words);
            raw_words=0;tensor_words=0;read_words=0;
        end
        $finish;
    end
    initial begin #50000000;$fatal(1,"test timeout");end
endmodule
