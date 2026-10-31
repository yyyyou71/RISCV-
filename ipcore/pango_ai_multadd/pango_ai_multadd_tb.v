

/////////////////////////////////////////////////////////////////////////////
//
// Copyright (c) 2014 PANGO MICROSYSTEMS, INC
// ALL RIGHTS REVERVED.
//
// THE SOURCE CODE CONTAINED HEREIN IS PROPRIETARY TO PANGO MICROSYSTEMS, INC.
// IT SHALL NOT BE REPRODUCED OR DISCLOSED IN WHOLE OR IN PART OR USED BY
// PARTIES WITHOUT WRITTEN AUTHORIZATION FROM THE OWNER.
//
//////////////////////////////////////////////////////////////////////////////
//
// Library:
// Filename:TB pango_ai_multadd_tb.v
//////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
module pango_ai_multadd_tb();
localparam  T_CLK_PERIOD       = 10     ;       //clock a half perid
localparam  T_RST_TIME         = 200    ;       //reset time
localparam  T_SIM_TIME         = 100000 ;       //reset time


localparam ASIZE = 16 ; //@IPC int 2,73

localparam BSIZE = 8 ; //@IPC int 2,73

localparam A_SIGNED = 1 ; //@IPC enum 0,1

localparam B_SIGNED = 1 ; //@IPC enum 0,1

localparam ASYNC_RST = 0 ; //@IPC enum 0,1

localparam OPTIMAL_TIMING = 0 ; //@IPC enum 0,1

localparam INREG_EN = 0 ; //@IPC enum 0,1

localparam PIPEREG_EN_1 = 1 ; //@IPC enum 0,1

localparam PIPEREG_EN_2 = 1 ; //@IPC enum 0,1

localparam PIPEREG_EN_3 = 1 ; //@IPC enum 0,1

localparam OUTREG_EN = 0 ; //@IPC enum 0,1

//tmp variable for ipc purpose

localparam PIPE_STATUS = 3 ; //@IPC enum 0,1,2,3,4,5

localparam ASYNC_RST_BOOL = 0 ; //@IPC bool

//end of tmp variable

localparam DYN_ADDSUB_OP = 0 ; //@IPC bool

localparam ADDSUB_OP = 0 ; //@IPC bool

localparam OPTIMAL_TIMING_BOOL = 0 ; //@IPC bool


localparam  PSIZE       = ASIZE + BSIZE +1    ;
 

//variable declaration
reg                 clk            ;
reg                 rst            ;
reg                 ce             ;
reg [ASIZE-1:0]     a0             ;
reg [ASIZE-1:0]     a1             ;
reg [BSIZE-1:0]     b0             ;
reg [BSIZE-1:0]     b1             ;
reg                 addsub;
wire [PSIZE-1:0]    p              ;

wire ADDSUB_OPCODE;

wire [139:0]        a0_ext         ;
wire [139:0]        a1_ext         ;
wire [139:0]        b0_ext         ;
wire [139:0]        b1_ext         ;
wire [279:0]        p_ext          ;
reg  [PSIZE-1:0]    p_ext_ff1      ;
reg  [PSIZE-1:0]    p_ext_ff2      ;
reg  [PSIZE-1:0]    p_ext_ff3      ;
reg  [PSIZE-1:0]    p_ext_ff4      ;
reg  [PSIZE-1:0]    p_ext_ff5      ;
wire [PSIZE-1:0]    p_multadd      ;
wire [PSIZE-1:0]    p_check        ;
 

reg  pass;

initial
begin
    clk = 1'b1;
    rst = 1'b1;
    #T_RST_TIME
    rst = 1'b0;
end

GTP_GRS   GRS_INST( .GRS_N(1'b1) );

initial begin
    a1     = {ASIZE{1'b0}};
    a0     = {ASIZE{1'b0}};
    b1     = {BSIZE{1'b0}};
    b0     = {BSIZE{1'b0}};
    addsub = 1'b0;
end

always #T_CLK_PERIOD  clk = ~clk;

always@(posedge clk)
begin

    a0 <= {$random,$random,$random};
    a1 <= {$random,$random,$random};
    b0 <= {$random,$random,$random};
    b1 <= {$random,$random,$random};
    addsub <= $random;

end

always@(negedge clk or posedge rst)
begin
    if(rst)
        ce <= 1'b1;
    else
        ce <= $random;
end

integer  result_fid;
initial
begin
    $display("Simulation Starts ...\n");
    result_fid = $fopen ("sim_results.log","a");
    #T_SIM_TIME;
    $display("Simulation is done.\n");
    if (pass == 1)
        $display("Simulation Success!\n");
    else
        $display("Simulation Failed!\n");
    $finish;
end


assign a0_ext = {{(140-ASIZE){a0[ASIZE-1]&&A_SIGNED}},a0[ASIZE-1:0]};
assign b0_ext = {{(140-BSIZE){b0[BSIZE-1]&&B_SIGNED}},b0[BSIZE-1:0]};
assign a1_ext = {{(140-ASIZE){a1[ASIZE-1]&&A_SIGNED}},a1[ASIZE-1:0]};
assign b1_ext = {{(140-BSIZE){b1[BSIZE-1]&&B_SIGNED}},b1[BSIZE-1:0]};


assign ADDSUB_OPCODE = (DYN_ADDSUB_OP == 1)? addsub : ADDSUB_OP;

assign p_ext = (ADDSUB_OPCODE == 0) ?a0_ext * b0_ext + a1_ext * b1_ext :a0_ext * b0_ext - a1_ext * b1_ext  ;


always@(posedge clk or posedge rst)
begin
    if(rst)
    begin
        p_ext_ff1 <= {PSIZE{1'b0}};
        p_ext_ff2 <= {PSIZE{1'b0}};
        p_ext_ff3 <= {PSIZE{1'b0}};
        p_ext_ff4 <= {PSIZE{1'b0}};
        p_ext_ff5 <= {PSIZE{1'b0}};
    end
    else if(ce)
    begin
        p_ext_ff1 <= p_ext[PSIZE-1:0];
        p_ext_ff2 <= p_ext_ff1;
        p_ext_ff3 <= p_ext_ff2;
        p_ext_ff4 <= p_ext_ff3;
        p_ext_ff5 <= p_ext_ff4;
    end
end

assign p_multadd = (PIPE_STATUS == 0 ) ? p_ext[PSIZE-1:0] :
                   (PIPE_STATUS == 1 ) ? p_ext_ff1 :
                   (PIPE_STATUS == 2 ) ? p_ext_ff2 :
                   (PIPE_STATUS == 3 ) ? p_ext_ff3 :
                   (PIPE_STATUS == 4 ) ? p_ext_ff4 : p_ext_ff5 ;


assign p_check = p_multadd;

always @(posedge clk or posedge rst)
begin
    if(rst)
        pass <= 1'b1;
    else if ( p_check !== p)
    begin
        $display("multadd error! multadd data = %h, product = %h",p_check,p);
        $fdisplay(result_fid, "err_chk=1");
        pass <= 1'b0;
    end
end

//***************************************************************** DUT  INST ********************************************************************************
pango_ai_multadd  U_pango_ai_multadd
(
    .ce     ( ce    ),
    .rst    ( rst   ),
    .clk    ( clk   ),
    .a0     ( a0    ),
    .a1     ( a1    ),
    .b0     ( b0    ),
    .b1     ( b1    ),
    
    .p      ( p     )
);

 endmodule
