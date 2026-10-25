"""Extend the instruction-at-a-time differential scoreboard to two ordered packets."""
def dualize_core_tb(source,wide):
    marker='    rv32_core #('
    assert source.count(marker)==1
    source=source.replace(marker,'''    wire tv2,tw2;
    wire [31:0] tpc2,tinsn2,tnpc2,trddata2,idata_second,taddr2,tdata2,trdata2;
    wire [3:0] tmask2,trmask2;
    wire [4:0] trd2;
    wire [447:0] packet2={tpc2,tinsn2,tnpc2,{31'b0,tw2},{27'b0,trd2},trddata2,
                         taddr2,{28'b0,tmask2},tdata2,{28'b0,trmask2},trdata2,32'b0,32'b0,32'b0};
    integer pair_packets=0;
'''+marker)
    source=source.replace('.imem_error(ie),',f".imem_error(ie),.imem_second_valid(1'b{int(bool(wide))} && ia[3:2]!=3),.imem_second_error(ia+4>=FAULT_BASE),.imem_rdata_second(idata_second),")
    source=source.replace('.retire_valid(tv),', '.retire2_mem_addr(taddr2),.retire2_mem_wmask(tmask2),.retire2_mem_rmask(trmask2),.retire2_mem_wdata(tdata2),.retire2_mem_rdata(trdata2),.retire2_valid(tv2),.retire2_rd_we(tw2),.retire2_pc(tpc2),.retire2_insn(tinsn2),.retire2_next_pc(tnpc2),.retire2_rd(trd2),.retire2_rd_data(trddata2),.retire_valid(tv),')
    marker="    assign idata = ie ? 32'b0 : {mem[ia+3],mem[ia+2],mem[ia+1],mem[ia]};"
    assert source.count(marker)==1
    source=source.replace(marker,marker+"\n    assign idata_second=ia+4>=FAULT_BASE?32'b0:{mem[ia+7],mem[ia+6],mem[ia+5],mem[ia+4]};")
    source=source.replace('            if (tv && !trap_seen) begin','''            if(tv2 && (!tv || tt || trap_seen)) $fatal(1,"Secondary retirement bypassed older instruction/trap");
            if(tv2 && (tpc2!==tnpc || tpc2!==tpc+4)) $fatal(1,"Unordered retirement pair");
            if (tv && !trap_seen) begin''')
    marker='''        end
    end

    task automatic initialize_case;'''
    assert source.count(marker)==1
    source=source.replace(marker,'''            if(tv2 && !trap_seen) begin
                if(index>=expected_count || packet2!==expected_trace[index]) begin
                    $display("DIFF_SECOND %s index=%0d expected=%0112x actual=%0112x",name,index,expected_trace[index],packet2);
                    $fatal(1,"Secondary architectural differential mismatch");
                end
                $fdisplay(tf,"%s %0d %0d %0112x",name,index,cycles,packet2);
                if(tw2) expected_regs[trd2]=trddata2;
                if(|tmask2)begin
                    expected_writes=expected_writes+1;
                    for(k=0;k<4;k=k+1)if(tmask2[k])expected_mem[(taddr2 & 32'hfffffffc)+k]=tdata2[8*k+:8];
                end
                if(|trmask2)expected_reads=expected_reads+1;
                index=index+1;pair_packets=pair_packets+1;
            end
'''+marker)
    source=source.replace('index = 0; wait_cycles = 0;', 'index = 0; pair_packets=0; wait_cycles = 0;')
    source=source.replace('full_pipeline,reads,writes"','full_pipeline,reads,writes,pairs"')
    lines=source.splitlines()
    for i,line in enumerate(lines):
        if '$fdisplay(rf,' in line and ',name,index,' in line:
            lines[i]=line.replace('",name,index,',',%0d",name,index,').replace('full_pipe,reads,writes);','full_pipe,reads,writes,pair_packets);')
    return '\n'.join(lines)+'\n'
