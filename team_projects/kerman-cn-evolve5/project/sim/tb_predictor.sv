`timescale 1ns/1ps
module tb_predictor;
    reg clk=0; always #5 clk=~clk;
    reg rst=1,qerror=0,uv=0,uc=0,ut=0;
    reg [31:0] qp=0,qi=0,up=0,ud=0;
    wire hit,taken,off_hit,off_taken;
    wire [31:0] next_pc,off_next;
    rv32_predictor #(.INDEX_BITS(2)) dut(.clk(clk),.rst(rst),.query_pc(qp),.query_insn(qi),.query_error(qerror),
      .hit(hit),.taken(taken),.next_pc(next_pc),.update_valid(uv),.update_conditional(uc),.update_taken(ut),.update_pc(up),.update_target(ud));
    rv32_predictor #(.ENABLE(0),.INDEX_BITS(2)) disabled(.clk(clk),.rst(rst),.query_pc(qp),.query_insn(qi),.query_error(qerror),
      .hit(off_hit),.taken(off_taken),.next_pc(off_next),.update_valid(uv),.update_conditional(uc),.update_taken(ut),.update_pc(up),.update_target(ud));
    integer file,scan,count=0;
    reg [31:0] a[0:14];
    task automatic check(input [31:0] eh,et,en);
        begin
            if({hit,taken,next_pc}!=={eh[0],et[0],en}) $fatal(1,"Predictor mismatch vector %0d pc=%08x got=%b/%b/%08x expected=%b/%b/%08x",count,qp,hit,taken,next_pc,eh[0],et[0],en);
            if(off_hit!==0 || off_taken!==0 || off_next!==(qp+32'd4)) $fatal(1,"Disabled predictor changed instruction flow");
        end
    endtask
    initial begin
        file=$fopen("bp_vectors.txt","r"); if(!file) $fatal(1,"Missing vectors");
        repeat(2) @(posedge clk);
        while(!$feof(file)) begin
            scan=$fscanf(file,"%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",a[0],a[1],a[2],a[3],a[4],a[5],a[6],a[7],a[8],a[9],a[10],a[11],a[12],a[13],a[14]);
            if(scan==15) begin
                @(negedge clk); rst=a[0][0]; qp=a[1]; qi=a[2]; qerror=a[3][0]; uv=a[4][0]; up=a[5]; ud=a[6]; ut=a[7][0]; uc=a[8][0];
                #1; check(a[9],a[10],a[11]);
                @(posedge clk); #1; check(a[12],a[13],a[14]); count=count+1;
            end
        end
        $fclose(file); $display("PREDICTOR_UNIT_PASS vectors=%0d",count); $finish;
    end
endmodule
