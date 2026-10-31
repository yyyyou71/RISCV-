
//////////////////////////////////////////////////////////////////////////////
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
// Filename:ipm2l_multadd.v
// Function: p=a0*b0+/-a1*b1
//           asize:2-73(singed)/72(unsigned)
//           bsize:2-66(singed)/65(unsigned)
//           psize:asize+bszie+1
//////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
module ipm2l_multadd_v1_3_pango_ai_multadd
#(
    parameter   ASIZE           = 54,
    parameter   BSIZE           = 27,
    parameter   PSIZE           = ASIZE + BSIZE+1,
    //signed
    parameter   A_SIGNED        = 0,
    parameter   B_SIGNED        = 0,

    parameter   OPTIMAL_TIMING  = 0,
    //pipeline
    parameter   INREG_EN        = 0,
    parameter   PIPEREG_EN_1    = 0,
    parameter   PIPEREG_EN_2    = 0,
    parameter   PIPEREG_EN_3    = 0,
    parameter   OUTREG_EN       = 0,

    parameter   GRS_EN          = "FALSE",      //"TRUE","FALSE",enable global reset
    parameter   ASYNC_RST       = 1,            // RST is sync/async

    parameter   ADDSUB_OP       = 0,
    parameter   DYN_ADDSUB_OP   = 1

)(
    input                       ce    ,
    input                       rst   ,
    input                       clk   ,
    input       [ASIZE-1:0]     a0    ,           //unsigned:72, signed:73
    input       [ASIZE-1:0]     a1    ,           //unsigned:72, signed:73
    input       [BSIZE-1:0]     b0    ,           //unsigned:65, signed:66
    input       [BSIZE-1:0]     b1    ,           //unsigned:65, signed:66
    input                       addsub,           //0:add 1:sub
    output wire [PSIZE-1:0]     p
);

localparam OPTIMAL_TIMING_BOOL = 0 ; //@IPC bool

localparam ASIZE_SIGNED  = (A_SIGNED == 1) ? ASIZE : (ASIZE + 1);

localparam BSIZE_SIGNED  = (B_SIGNED == 1) ? BSIZE : (BSIZE + 1);

localparam MAX_DATA_SIZE = (ASIZE_SIGNED >= BSIZE_SIGNED)? ASIZE_SIGNED : BSIZE_SIGNED;

localparam MIN_DATA_SIZE = (ASIZE_SIGNED <  BSIZE_SIGNED)? ASIZE_SIGNED : BSIZE_SIGNED;

localparam USE_SIMD      = (MAX_DATA_SIZE <= 12 && MIN_DATA_SIZE <= 9) ? 1 : 0;  // single addsub25_mult25_add48 / dual addsub12_mult12_add24

localparam USE_POSTADD   = 1'b1;

//****************************************data_size error check**********************************************************
localparam N = (MIN_DATA_SIZE < 2 )  ? 0 :
               (MAX_DATA_SIZE <= 25 && MIN_DATA_SIZE <= 18) ? 2  :       //25x18+25x18
               (MAX_DATA_SIZE <= 34 && MIN_DATA_SIZE <= 25) ? 4  :       //25x34+25x34
               (MAX_DATA_SIZE <= 49 && MIN_DATA_SIZE <= 18) ? 4  :       //49x18+49x18
               (MAX_DATA_SIZE <= 50 && MIN_DATA_SIZE <= 25) ? 6  :       //25x50+25x50
               (MAX_DATA_SIZE <= 73 && MIN_DATA_SIZE <= 18) ? 6  :       //73x18+73x18
               (MAX_DATA_SIZE <= 66 && MIN_DATA_SIZE <= 25) ? 8  :       //25x66+25x66
               (MAX_DATA_SIZE <= 49 && MIN_DATA_SIZE <= 34) ? 8  :       //49x34+49x34
               (MAX_DATA_SIZE <= 50 && MIN_DATA_SIZE <= 49) ? 12 :       //49x50+49x50
               (MAX_DATA_SIZE <= 73 && MIN_DATA_SIZE <= 34) ? 12 :       //73x34+73x34
               (MAX_DATA_SIZE <= 66 && MIN_DATA_SIZE <= 49) ? 16 :       //49x66+49x66
               (MAX_DATA_SIZE <= 73 && MIN_DATA_SIZE <= 50) ? 18 :       //73x50+73x50
               (MAX_DATA_SIZE <= 73 && MIN_DATA_SIZE <= 66) ? 24 : 0 ;   //73x66+73x66

localparam GTP_APM_E2_NUM = N/2;
//****************************************************************DATA WIDTH****************************************
localparam M_A_DATA_WIDTH   = (MAX_DATA_SIZE <= 12 && MIN_DATA_SIZE <= 9 ) ? MAX_DATA_SIZE :                   //12x9 +12x9
                              (MAX_DATA_SIZE <= 25 && MIN_DATA_SIZE <= 18) ? MAX_DATA_SIZE :                   //25x18+25x18
                              (MAX_DATA_SIZE <= 34 && MIN_DATA_SIZE <= 25) ? MIN_DATA_SIZE :                   //25x34+25x34
                              (MAX_DATA_SIZE <= 49 && MIN_DATA_SIZE <= 18) ? MAX_DATA_SIZE :                   //49x18+49x18
                              (MAX_DATA_SIZE <= 50 && MIN_DATA_SIZE <= 25) ? MIN_DATA_SIZE :                   //25x50+25x50
                              (MAX_DATA_SIZE <= 73 && MIN_DATA_SIZE <= 18) ? MAX_DATA_SIZE :                   //73x18+73x18
                              (MAX_DATA_SIZE <= 66 && MIN_DATA_SIZE <= 25) ? MIN_DATA_SIZE :                   //25x66+25x66
                              (MAX_DATA_SIZE <= 49 && MIN_DATA_SIZE <= 34) ? MAX_DATA_SIZE :                   //49x34+49x34
                              (MAX_DATA_SIZE <= 50 && MIN_DATA_SIZE <= 49) ? MIN_DATA_SIZE :                   //49x50+49x50
                              (MAX_DATA_SIZE <= 73 && MIN_DATA_SIZE <= 34) ? MAX_DATA_SIZE :                   //73x34+73x34
                              (MAX_DATA_SIZE <= 66 && MIN_DATA_SIZE <= 49) ? MIN_DATA_SIZE :                   //49x66+49x66
                              (MAX_DATA_SIZE <= 73 && MIN_DATA_SIZE <= 50) ? MAX_DATA_SIZE :                   //73x50+73x50
                              (MAX_DATA_SIZE <= 73 && MIN_DATA_SIZE <= 66) ? MAX_DATA_SIZE : MAX_DATA_SIZE;    //73x66+73x66


localparam M_B_DATA_WIDTH   = (MAX_DATA_SIZE <= 12 && MIN_DATA_SIZE <= 9 ) ? MIN_DATA_SIZE :                   //12x9 +12x9
                              (MAX_DATA_SIZE <= 25 && MIN_DATA_SIZE <= 18) ? MIN_DATA_SIZE :                   //25x18+25x18
                              (MAX_DATA_SIZE <= 34 && MIN_DATA_SIZE <= 25) ? MAX_DATA_SIZE :                   //25x34+25x34
                              (MAX_DATA_SIZE <= 49 && MIN_DATA_SIZE <= 18) ? MIN_DATA_SIZE :                   //49x18+49x18
                              (MAX_DATA_SIZE <= 50 && MIN_DATA_SIZE <= 25) ? MAX_DATA_SIZE :                   //25x50+25x50
                              (MAX_DATA_SIZE <= 73 && MIN_DATA_SIZE <= 18) ? MIN_DATA_SIZE :                   //73x18+73x18
                              (MAX_DATA_SIZE <= 66 && MIN_DATA_SIZE <= 25) ? MAX_DATA_SIZE :                   //25x66+25x66
                              (MAX_DATA_SIZE <= 49 && MIN_DATA_SIZE <= 34) ? MIN_DATA_SIZE :                   //49x34+49x34
                              (MAX_DATA_SIZE <= 50 && MIN_DATA_SIZE <= 49) ? MAX_DATA_SIZE :                   //49x50+49x50
                              (MAX_DATA_SIZE <= 73 && MIN_DATA_SIZE <= 34) ? MIN_DATA_SIZE :                   //73x34+73x34
                              (MAX_DATA_SIZE <= 66 && MIN_DATA_SIZE <= 49) ? MAX_DATA_SIZE :                   //49x66+49x66
                              (MAX_DATA_SIZE <= 73 && MIN_DATA_SIZE <= 50) ? MIN_DATA_SIZE :                   //73x50+73x50
                              (MAX_DATA_SIZE <= 73 && MIN_DATA_SIZE <= 66) ? MIN_DATA_SIZE : MIN_DATA_SIZE;    //73x66+73x66

//****************************************************************GTP_APM_E2 cascade****************************************
localparam [11:0] CPO_REG   = (OPTIMAL_TIMING == 0 ) ? 12'b0 : 12'h7_ff;


//**************************************************************************************************************************
initial
begin
    if (N == 0)
        $display("apm_mult parameter setting error!!! DATA_SIZE must between 2*2-73*66(signed)/72*65(unsigned)");
end

//**********************************************************reg & wire******************************************************
wire [ASIZE_SIGNED-1:0]     a0_signed;
wire [ASIZE_SIGNED-1:0]     a1_signed;
wire [BSIZE_SIGNED-1:0]     b0_signed;
wire [BSIZE_SIGNED-1:0]     b1_signed;

wire [MAX_DATA_SIZE-1:0]    max_data0;
wire [MAX_DATA_SIZE-1:0]    max_data1;
wire [MIN_DATA_SIZE-1:0]    min_data0;
wire [MIN_DATA_SIZE-1:0]    min_data1;

wire [M_A_DATA_WIDTH-1:0]   m_a0;
wire [M_A_DATA_WIDTH-1:0]   m_a1;
wire [M_B_DATA_WIDTH-1:0]   m_b0;
wire [M_B_DATA_WIDTH-1:0]   m_b1;

wire [47:0]     m_p[11:0];
wire [47:0]     cpo[24:0];

wire [24:0]     m_a0_0;
wire [24:0]     m_a1_0;
wire [24:0]     m_a0_1;
wire [24:0]     m_a1_1;
wire [24:0]     m_a0_2;
wire [24:0]     m_a1_2;
wire [17:0]     m_b0_0;
wire [17:0]     m_b1_0;
wire [17:0]     m_b0_1;
wire [17:0]     m_b1_1;
wire [17:0]     m_b0_2;
wire [17:0]     m_b1_2;
wire [17:0]     m_b0_3;
wire [17:0]     m_b1_3;
wire [72:0]     m_a0_sign_ext;
wire [72:0]     m_a1_sign_ext;
wire [65:0]     m_b0_sign_ext;
wire [65:0]     m_b1_sign_ext;

reg  [2:0]      modez_in[11:0]; //3'd0:add zero;
                                //3'd3:shift 0 ;
                                //3'd4:shift 17;
                                //3'd5:shift 24;
                                //3'd6:shift 16;
                                //3'd7:shift 8 ;

reg  [24:0]     m_a0_div   [11:0];
reg  [24:0]     m_a1_div   [11:0];
reg  [24:0]     m_a0_div_ff[11:0];
reg  [24:0]     m_a1_div_ff[11:0];
reg  [17:0]     m_b0_div   [11:0];
reg  [17:0]     m_b1_div   [11:0];
reg  [17:0]     m_b0_div_ff[11:0];
reg  [17:0]     m_b1_div_ff[11:0];
wire [24:0]     m_a0_in    [11:0];
wire [24:0]     m_a1_in    [11:0];
wire [17:0]     m_b0_in    [11:0];
wire [17:0]     m_b1_in    [11:0];


wire [139:0]    m_p_o     ;
reg  [139:0]    m_p_o_ff  ;

//addsub
reg             addsub_ff1    ;
reg             addsub_ff2    ;
wire            addsub_real   ;
wire [11:0]     addsub_in     ;
reg  [10:0]     addsub_real_ff;

wire            rst_sync      ;
wire            rst_async     ;

//rst
assign rst_sync  = (ASYNC_RST == 0)  ? rst : 1'b0;
assign rst_async = (ASYNC_RST == 1)  ? rst : 1'b0;

assign a0_signed = (A_SIGNED == 1) ? a0 : {1'b0,a0}; //unsigned -> signed
assign a1_signed = (A_SIGNED == 1) ? a1 : {1'b0,a1}; //unsigned -> signed
assign b0_signed = (B_SIGNED == 1) ? b0 : {1'b0,b0}; //unsigned -> signed
assign b1_signed = (B_SIGNED == 1) ? b1 : {1'b0,b1}; //unsigned -> signed

assign max_data0 = (ASIZE_SIGNED >= BSIZE_SIGNED) ? a0_signed : b0_signed;
assign max_data1 = (ASIZE_SIGNED >= BSIZE_SIGNED) ? a1_signed : b1_signed;
assign min_data0 = (ASIZE_SIGNED <  BSIZE_SIGNED) ? a0_signed : b0_signed;
assign min_data1 = (ASIZE_SIGNED <  BSIZE_SIGNED) ? a1_signed : b1_signed;

generate
begin
    if(MAX_DATA_SIZE <= 12 && MIN_DATA_SIZE <= 9 )          //12x9
    begin
        assign m_a0 = max_data0;
        assign m_a1 = max_data1;
        assign m_b0 = min_data0;
        assign m_b1 = min_data1;
    end
    else if (MAX_DATA_SIZE <= 25 && MIN_DATA_SIZE <= 18)    //25x18
    begin
        assign m_a0 = max_data0;
        assign m_a1 = max_data1;
        assign m_b0 = min_data0;
        assign m_b1 = min_data1;
    end
    else if (MAX_DATA_SIZE <= 34 && MIN_DATA_SIZE <= 25)    //25x34
    begin
        assign m_a0 = min_data0;
        assign m_a1 = min_data1;
        assign m_b0 = max_data0;
        assign m_b1 = max_data1;
    end
    else if (MAX_DATA_SIZE <= 49 && MIN_DATA_SIZE <= 18)    //49x18
    begin
        assign m_a0 = max_data0;
        assign m_a1 = max_data1;
        assign m_b0 = min_data0;
        assign m_b1 = min_data1;
    end
    else if (MAX_DATA_SIZE <= 50 && MIN_DATA_SIZE <= 25)    //25x50
    begin
        assign m_a0 = min_data0;
        assign m_a1 = min_data1;
        assign m_b0 = max_data0;
        assign m_b1 = max_data1;
    end
    else if (MAX_DATA_SIZE <= 73 && MIN_DATA_SIZE <= 18)    //73x18
    begin
        assign m_a0 = max_data0;
        assign m_a1 = max_data1;
        assign m_b0 = min_data0;
        assign m_b1 = min_data1;
    end
    else if (MAX_DATA_SIZE <= 66 && MIN_DATA_SIZE <= 25)    //25x66
    begin
        assign m_a0 = min_data0;
        assign m_a1 = min_data1;
        assign m_b0 = max_data0;
        assign m_b1 = max_data1;
    end
    else if (MAX_DATA_SIZE <= 49 && MIN_DATA_SIZE <= 34)    //49x34
    begin
        assign m_a0 = max_data0;
        assign m_a1 = max_data1;
        assign m_b0 = min_data0;
        assign m_b1 = min_data1;
    end
    else if (MAX_DATA_SIZE <= 50 && MIN_DATA_SIZE <= 49)    //49x50
    begin
        assign m_a0 = min_data0;
        assign m_a1 = min_data1;
        assign m_b0 = max_data0;
        assign m_b1 = max_data1;
    end
    else if (MAX_DATA_SIZE <= 73 && MIN_DATA_SIZE <= 34)    //73x34
    begin
        assign m_a0 = max_data0;
        assign m_a1 = max_data1;
        assign m_b0 = min_data0;
        assign m_b1 = min_data1;
    end
    else if (MAX_DATA_SIZE <= 66 && MIN_DATA_SIZE <= 49)    //49x66
    begin
        assign m_a0 = min_data0;
        assign m_a1 = min_data1;
        assign m_b0 = max_data0;
        assign m_b1 = max_data1;
    end
    else if (MAX_DATA_SIZE <= 73 && MIN_DATA_SIZE <= 50)    //73x50
    begin
        assign m_a0 = max_data0;
        assign m_a1 = max_data1;
        assign m_b0 = min_data0;
        assign m_b1 = min_data1;
    end
    else if (MAX_DATA_SIZE <= 73 && MIN_DATA_SIZE <= 66)    //73x66
    begin
        assign m_a0 = max_data0;
        assign m_a1 = max_data1;
        assign m_b0 = min_data0;
        assign m_b1 = min_data1;
    end
end
endgenerate

//*******************************************************partition input data***********************************************
generate
    if(M_A_DATA_WIDTH == 73)
    begin
        assign m_a0_sign_ext = m_a0;
        assign m_a1_sign_ext = m_a1;
    end
    else
    begin
        assign m_a0_sign_ext = {{{73-M_A_DATA_WIDTH}{m_a0[M_A_DATA_WIDTH-1]}},m_a0};
        assign m_a1_sign_ext = {{{73-M_A_DATA_WIDTH}{m_a1[M_A_DATA_WIDTH-1]}},m_a1};
    end
endgenerate
generate
    if(M_B_DATA_WIDTH == 66)
    begin
        assign m_b0_sign_ext = m_b0;
        assign m_b1_sign_ext = m_b1;
    end
    else
    begin
        assign m_b0_sign_ext = {{{66-M_B_DATA_WIDTH}{m_b0[M_B_DATA_WIDTH-1]}},m_b0};
        assign m_b1_sign_ext = {{{66-M_B_DATA_WIDTH}{m_b1[M_B_DATA_WIDTH-1]}},m_b1};
    end
endgenerate
//partition data a
generate
begin:partition_data_a
    if (M_A_DATA_WIDTH <= 25)
    begin
        assign m_a0_0 = m_a0_sign_ext[24:0];
        assign m_a1_0 = m_a1_sign_ext[24:0];
    end
    else if (M_A_DATA_WIDTH <= 49)
    begin
        assign m_a0_0 = {1'b0,m_a0_sign_ext[23:0]};
        assign m_a1_0 = {1'b0,m_a1_sign_ext[23:0]};
        assign m_a0_1 = m_a0_sign_ext[48:24];
        assign m_a1_1 = m_a1_sign_ext[48:24];
    end
    else if (M_A_DATA_WIDTH <= 73)
    begin
        assign m_a0_0 = {1'b0,m_a0_sign_ext[23:0]};
        assign m_a1_0 = {1'b0,m_a1_sign_ext[23:0]};
        assign m_a0_1 = {1'b0,m_a0_sign_ext[47:24]};
        assign m_a1_1 = {1'b0,m_a1_sign_ext[47:24]};
        assign m_a0_2 = m_a0_sign_ext[72:48];
        assign m_a1_2 = m_a1_sign_ext[72:48];
    end
end
endgenerate

//partition data b
generate
begin:partition_data_b
    if (M_B_DATA_WIDTH <= 18)
    begin
        assign m_b0_0 = m_b0_sign_ext[17:0];
        assign m_b1_0 = m_b1_sign_ext[17:0];
    end
    else if (M_B_DATA_WIDTH <= 34)
    begin
        assign m_b0_0 = {2'b0,m_b0_sign_ext[15:0]};
        assign m_b1_0 = {2'b0,m_b1_sign_ext[15:0]};
        assign m_b0_1 = m_b0_sign_ext[33:16];
        assign m_b1_1 = m_b1_sign_ext[33:16];
    end
    else if (M_B_DATA_WIDTH <= 50)
    begin
        assign m_b0_0 = {2'b0,m_b0_sign_ext[15:0]};
        assign m_b1_0 = {2'b0,m_b1_sign_ext[15:0]};
        assign m_b0_1 = {2'b0,m_b0_sign_ext[31:16]};
        assign m_b1_1 = {2'b0,m_b1_sign_ext[31:16]};
        assign m_b0_2 = m_b0_sign_ext[49:32];
        assign m_b1_2 = m_b1_sign_ext[49:32];
    end
    else if (M_B_DATA_WIDTH <= 66)
    begin
        assign m_b0_0 = {2'b0,m_b0_sign_ext[15:0]};
        assign m_b1_0 = {2'b0,m_b1_sign_ext[15:0]};
        assign m_b0_1 = {2'b0,m_b0_sign_ext[31:16]};
        assign m_b1_1 = {2'b0,m_b1_sign_ext[31:16]};
        assign m_b0_2 = {2'b0,m_b0_sign_ext[47:32]};
        assign m_b1_2 = {2'b0,m_b1_sign_ext[47:32]};
        assign m_b0_3 = m_b0_sign_ext[65:48];
        assign m_b1_3 = m_b1_sign_ext[65:48];
    end
end
endgenerate

//*******************************************************addsub***************************************************************
always@(posedge clk or posedge rst_async)
begin
    if (rst_async)
    begin
        addsub_ff1 <= 1'b0;
        addsub_ff2 <= 1'b0;
    end
    else if (rst_sync)
    begin
        addsub_ff1 <= 1'b0;
        addsub_ff2 <= 1'b0;
    end
    else if (ce)
    begin
        addsub_ff1 <= (DYN_ADDSUB_OP == 1)? addsub : ADDSUB_OP;
        addsub_ff2 <= addsub_ff1;
    end
end

assign addsub_real = (PIPEREG_EN_2 == 1 && INREG_EN == 1) ? addsub_ff2 :
                     (INREG_EN     == 1) ? addsub_ff1 :
                     (PIPEREG_EN_2 == 1) ? addsub_ff1 : (DYN_ADDSUB_OP == 1) ? addsub : ADDSUB_OP;

assign addsub_in[11:0] = {12{addsub_real}};

//*******************************************************input data for GTP***********************************************************
generate
begin:data_for_GTP
    if (MAX_DATA_SIZE <= 12 && MIN_DATA_SIZE <= 9 ) //12x9
    begin:mode_12_9
        always@(*)
        begin
            m_a0_div[0]  = {13'b0,m_a0_0[11:0]};
            m_a1_div[0]  = {13'b0,m_a1_0[11:0]};
            m_b0_div[0]  = {9'b0,m_b0_0[8:0]};
            m_b1_div[0]  = {9'b0,m_b1_0[8:0]};
            modez_in[0]  = 3'd0;
        end
    end
    else if (MAX_DATA_SIZE <= 25 && MIN_DATA_SIZE <= 18) //25x18
    begin:mode_25_18
        always@(*)
        begin
            m_a0_div[0]  = m_a0_0;
            m_a1_div[0]  = m_a1_0;
            m_b0_div[0]  = m_b0_0;
            m_b1_div[0]  = m_b1_0;
            modez_in[0]  = 3'd0;
        end
    end
    else if (MAX_DATA_SIZE <= 34 && MIN_DATA_SIZE <= 25) //25x34
    begin:mode_25_34
        always@(*)
        begin
            m_a0_div[0]  = m_a0_0;
            m_a1_div[0]  = m_a1_0;
            m_a0_div[1]  = m_a0_0;
            m_a1_div[1]  = m_a1_0;
            m_b0_div[0]  = m_b0_0;
            m_b1_div[0]  = m_b1_0;
            m_b0_div[1]  = m_b0_1;
            m_b1_div[1]  = m_b1_1;
            modez_in[0]  = 3'd0;
            modez_in[1]  = 3'd6; //shift 16
        end
    end
    else if (MAX_DATA_SIZE <= 49 && MIN_DATA_SIZE <= 18)  //49x18
    begin:mode_49_18
        always@(*)
        begin
            m_a0_div[0]  = m_a0_0;
            m_a1_div[0]  = m_a1_0;
            m_a0_div[1]  = m_a0_1;
            m_a1_div[1]  = m_a1_1;
            m_b0_div[0]  = m_b0_0;
            m_b1_div[0]  = m_b1_0;
            m_b0_div[1]  = m_b0_0;
            m_b1_div[1]  = m_b1_0;
            modez_in[0]  = 3'd0;
            modez_in[1]  = 3'd5; //shift 24
        end
    end
    else if (MAX_DATA_SIZE <= 50 && MIN_DATA_SIZE <= 25) //25x50
    begin:mode_25_50
        always@(*)
        begin
            m_a0_div[0]  = m_a0_0;
            m_a1_div[0]  = m_a1_0;
            m_a0_div[1]  = m_a0_0;
            m_a1_div[1]  = m_a1_0;
            m_a0_div[2]  = m_a0_0;
            m_a1_div[2]  = m_a1_0;
            m_b0_div[0]  = m_b0_0;
            m_b1_div[0]  = m_b1_0;
            m_b0_div[1]  = m_b0_1;
            m_b1_div[1]  = m_b1_1;
            m_b0_div[2]  = m_b0_2;
            m_b1_div[2]  = m_b1_2;
            modez_in[0]  = 3'd0;
            modez_in[1]  = 3'd6; //shift 16
            modez_in[2]  = 3'd6; //shift 16
        end
    end
    else if (MAX_DATA_SIZE <= 73 && MIN_DATA_SIZE <= 18) //73x18
    begin:mode_73_18
        always@(*)
        begin
            m_a0_div[0]  = m_a0_0;
            m_a1_div[0]  = m_a1_0;
            m_a0_div[1]  = m_a0_1;
            m_a1_div[1]  = m_a1_1;
            m_a0_div[2]  = m_a0_2;
            m_a1_div[2]  = m_a1_2;
            m_b0_div[0]  = m_b0_0;
            m_b1_div[0]  = m_b1_0;
            m_b0_div[1]  = m_b0_0;
            m_b1_div[1]  = m_b1_0;
            m_b0_div[2]  = m_b0_0;
            m_b1_div[2]  = m_b1_0;
            modez_in[0]  = 3'd0;
            modez_in[1]  = 3'd5; //shift 24
            modez_in[2]  = 3'd5; //shift 24
        end
    end
    else if (MAX_DATA_SIZE <= 66 && MIN_DATA_SIZE <= 25) //25x66
    begin:mode_25_66
        always@(*)
        begin
            m_a0_div[0]  = m_a0_0;
            m_a1_div[0]  = m_a1_0;
            m_a0_div[1]  = m_a0_0;
            m_a1_div[1]  = m_a1_0;
            m_a0_div[2]  = m_a0_0;
            m_a1_div[2]  = m_a1_0;
            m_a0_div[3]  = m_a0_0;
            m_a1_div[3]  = m_a1_0;
            m_b0_div[0]  = m_b0_0;
            m_b1_div[0]  = m_b1_0;
            m_b0_div[1]  = m_b0_1;
            m_b1_div[1]  = m_b1_1;
            m_b0_div[2]  = m_b0_2;
            m_b1_div[2]  = m_b1_2;
            m_b0_div[3]  = m_b0_3;
            m_b1_div[3]  = m_b1_3;
            modez_in[0]  = 3'd0;
            modez_in[1]  = 3'd6; //shift 16
            modez_in[2]  = 3'd6; //shift 16
            modez_in[3]  = 3'd6; //shift 16
        end
    end
    else if (MAX_DATA_SIZE <= 49 && MIN_DATA_SIZE <= 34) //49x34
    begin:mode_49_34
        always@(*)
        begin
            m_a0_div[0]  = m_a0_0;
            m_a1_div[0]  = m_a1_0;
            m_a0_div[1]  = m_a0_0;
            m_a1_div[1]  = m_a1_0;
            m_a0_div[2]  = m_a0_1;
            m_a1_div[2]  = m_a1_1;
            m_a0_div[3]  = m_a0_1;
            m_a1_div[3]  = m_a1_1;
            m_b0_div[0]  = m_b0_0;
            m_b1_div[0]  = m_b1_0;
            m_b0_div[1]  = m_b0_1;
            m_b1_div[1]  = m_b1_1;
            m_b0_div[2]  = m_b0_0;
            m_b1_div[2]  = m_b1_0;
            m_b0_div[3]  = m_b0_1;
            m_b1_div[3]  = m_b1_1;
            modez_in[0]  = 3'd0;
            modez_in[1]  = 3'd6; //shift 16
            modez_in[2]  = 3'd7; //shift 8
            modez_in[3]  = 3'd6; //shift 16
        end
    end
    else if (MAX_DATA_SIZE <= 50 && MIN_DATA_SIZE <= 49) //49x50
    begin:mode_49_50
        always@(*)
        begin
            m_a0_div[0]  = m_a0_0;
            m_a1_div[0]  = m_a1_0;
            m_a0_div[1]  = m_a0_0;
            m_a1_div[1]  = m_a1_0;
            m_a0_div[2]  = m_a0_1;
            m_a1_div[2]  = m_a1_1;
            m_a0_div[3]  = m_a0_0;
            m_a1_div[3]  = m_a1_0;
            m_a0_div[4]  = m_a0_1;
            m_a1_div[4]  = m_a1_1;
            m_a0_div[5]  = m_a0_1;
            m_a1_div[5]  = m_a1_1;
            m_b0_div[0]  = m_b0_0;
            m_b1_div[0]  = m_b1_0;
            m_b0_div[1]  = m_b0_1;
            m_b1_div[1]  = m_b1_1;
            m_b0_div[2]  = m_b0_0;
            m_b1_div[2]  = m_b1_0;
            m_b0_div[3]  = m_b0_2;
            m_b1_div[3]  = m_b1_2;
            m_b0_div[4]  = m_b0_1;
            m_b1_div[4]  = m_b1_1;
            m_b0_div[5]  = m_b0_2;
            m_b1_div[5]  = m_b1_2;
            modez_in[0]  = 3'd0;
            modez_in[1]  = 3'd6; //shift 16
            modez_in[2]  = 3'd7; //shift 8
            modez_in[3]  = 3'd7; //shift 8
            modez_in[4]  = 3'd7; //shift 8
            modez_in[5]  = 3'd6; //shift 16
        end
    end
    else if (MAX_DATA_SIZE <= 73 && MIN_DATA_SIZE <= 34) //73x34
    begin:mode_73_34
        always@(*)
        begin
            m_a0_div[0]  = m_a0_0;
            m_a1_div[0]  = m_a1_0;
            m_a0_div[1]  = m_a0_0;
            m_a1_div[1]  = m_a1_0;
            m_a0_div[2]  = m_a0_1;
            m_a1_div[2]  = m_a1_1;
            m_a0_div[3]  = m_a0_1;
            m_a1_div[3]  = m_a1_1;
            m_a0_div[4]  = m_a0_2;
            m_a1_div[4]  = m_a1_2;
            m_a0_div[5]  = m_a0_2;
            m_a1_div[5]  = m_a1_2;
            m_b0_div[0]  = m_b0_0;
            m_b1_div[0]  = m_b1_0;
            m_b0_div[1]  = m_b0_1;
            m_b1_div[1]  = m_b1_1;
            m_b0_div[2]  = m_b0_0;
            m_b1_div[2]  = m_b1_0;
            m_b0_div[3]  = m_b0_1;
            m_b1_div[3]  = m_b1_1;
            m_b0_div[4]  = m_b0_0;
            m_b1_div[4]  = m_b1_0;
            m_b0_div[5]  = m_b0_1;
            m_b1_div[5]  = m_b1_1;
            modez_in[0]  = 3'd0;
            modez_in[1]  = 3'd6; //shift 16
            modez_in[2]  = 3'd7; //shift 8
            modez_in[3]  = 3'd6; //shift 16
            modez_in[4]  = 3'd7; //shift 8
            modez_in[5]  = 3'd6; //shift 16
        end
    end
    else if (MAX_DATA_SIZE <= 66 && MIN_DATA_SIZE <= 49) //49x66
    begin:mode_49_66
        always@(*)
        begin
            m_a0_div[0]  = m_a0_0;
            m_a1_div[0]  = m_a1_0;
            m_a0_div[1]  = m_a0_0;
            m_a1_div[1]  = m_a1_0;
            m_a0_div[2]  = m_a0_1;
            m_a1_div[2]  = m_a1_1;
            m_a0_div[3]  = m_a0_0;
            m_a1_div[3]  = m_a1_0;
            m_a0_div[4]  = m_a0_1;
            m_a1_div[4]  = m_a1_1;
            m_a0_div[5]  = m_a0_0;
            m_a1_div[5]  = m_a1_0;
            m_a0_div[6]  = m_a0_1;
            m_a1_div[6]  = m_a1_1;
            m_a0_div[7]  = m_a0_1;
            m_a1_div[7]  = m_a1_1;
            m_b0_div[0]  = m_b0_0;
            m_b1_div[0]  = m_b1_0;
            m_b0_div[1]  = m_b0_1;
            m_b1_div[1]  = m_b1_1;
            m_b0_div[2]  = m_b0_0;
            m_b1_div[2]  = m_b1_0;
            m_b0_div[3]  = m_b0_2;
            m_b1_div[3]  = m_b1_2;
            m_b0_div[4]  = m_b0_1;
            m_b1_div[4]  = m_b1_1;
            m_b0_div[5]  = m_b0_3;
            m_b1_div[5]  = m_b1_3;
            m_b0_div[6]  = m_b0_2;
            m_b1_div[6]  = m_b1_2;
            m_b0_div[7]  = m_b0_3;
            m_b1_div[7]  = m_b1_3;
            modez_in[0]  = 3'd0;
            modez_in[1]  = 3'd6; //shift 16
            modez_in[2]  = 3'd7; //shift 8
            modez_in[3]  = 3'd7; //shift 8
            modez_in[4]  = 3'd7; //shift 8
            modez_in[5]  = 3'd7; //shift 8
            modez_in[6]  = 3'd7; //shift 8
            modez_in[7]  = 3'd6; //shift 16
        end
    end
    else if (MAX_DATA_SIZE <= 73 && MIN_DATA_SIZE <= 50) //73x50
    begin:mode_73_50
        always@(*)
        begin
            m_a0_div[0]  = m_a0_0;
            m_a1_div[0]  = m_a1_0;
            m_a0_div[1]  = m_a0_0;
            m_a1_div[1]  = m_a1_0;
            m_a0_div[2]  = m_a0_1;
            m_a1_div[2]  = m_a1_1;
            m_a0_div[3]  = m_a0_0;
            m_a1_div[3]  = m_a1_0;
            m_a0_div[4]  = m_a0_1;
            m_a1_div[4]  = m_a1_1;
            m_a0_div[5]  = m_a0_2;
            m_a1_div[5]  = m_a1_2;
            m_a0_div[6]  = m_a0_1;
            m_a1_div[6]  = m_a1_1;
            m_a0_div[7]  = m_a0_2;
            m_a1_div[7]  = m_a1_2;
            m_a0_div[8]  = m_a0_2;
            m_a1_div[8]  = m_a1_2;
            m_b0_div[0]  = m_b0_0;
            m_b1_div[0]  = m_b1_0;
            m_b0_div[1]  = m_b0_1;
            m_b1_div[1]  = m_b1_1;
            m_b0_div[2]  = m_b0_0;
            m_b1_div[2]  = m_b1_0;
            m_b0_div[3]  = m_b0_2;
            m_b1_div[3]  = m_b1_2;
            m_b0_div[4]  = m_b0_1;
            m_b1_div[4]  = m_b1_1;
            m_b0_div[5]  = m_b0_0;
            m_b1_div[5]  = m_b1_0;
            m_b0_div[6]  = m_b0_2;
            m_b1_div[6]  = m_b1_2;
            m_b0_div[7]  = m_b0_1;
            m_b1_div[7]  = m_b1_1;
            m_b0_div[8]  = m_b0_2;
            m_b1_div[8]  = m_b1_2;
            modez_in[0]  = 3'd0;
            modez_in[1]  = 3'd6; //shift 16
            modez_in[2]  = 3'd7; //shift 8
            modez_in[3]  = 3'd7; //shift 8
            modez_in[4]  = 3'd7; //shift 8
            modez_in[5]  = 3'd7; //shift 8
            modez_in[6]  = 3'd7; //shift 8
            modez_in[7]  = 3'd7; //shift 8
            modez_in[8]  = 3'd6; //shift 16
        end
    end
    else if (MAX_DATA_SIZE <= 73 && MIN_DATA_SIZE <= 66) //73x66
    begin:mode_73_66
        always@(*)
        begin
            m_a0_div[0]  = m_a0_0;
            m_a1_div[0]  = m_a1_0;
            m_a0_div[1]  = m_a0_0;
            m_a1_div[1]  = m_a1_0;
            m_a0_div[2]  = m_a0_1;
            m_a1_div[2]  = m_a1_1;
            m_a0_div[3]  = m_a0_0;
            m_a1_div[3]  = m_a1_0;
            m_a0_div[4]  = m_a0_1;
            m_a1_div[4]  = m_a1_1;
            m_a0_div[5]  = m_a0_0;
            m_a1_div[5]  = m_a1_0;
            m_a0_div[6]  = m_a0_2;
            m_a1_div[6]  = m_a1_2;
            m_a0_div[7]  = m_a0_1;
            m_a1_div[7]  = m_a1_1;
            m_a0_div[8]  = m_a0_2;
            m_a1_div[8]  = m_a1_2;
            m_a0_div[9]  = m_a0_1;
            m_a1_div[9]  = m_a1_1;
            m_a0_div[10] = m_a0_2;
            m_a1_div[10] = m_a1_2;
            m_a0_div[11] = m_a0_2;
            m_a1_div[11] = m_a1_2;
            m_b0_div[0]  = m_b0_0;
            m_b1_div[0]  = m_b1_0;
            m_b0_div[1]  = m_b0_1;
            m_b1_div[1]  = m_b1_1;
            m_b0_div[2]  = m_b0_0;
            m_b1_div[2]  = m_b1_0;
            m_b0_div[3]  = m_b0_2;
            m_b1_div[3]  = m_b1_2;
            m_b0_div[4]  = m_b0_1;
            m_b1_div[4]  = m_b1_1;
            m_b0_div[5]  = m_b0_3;
            m_b1_div[5]  = m_b1_3;
            m_b0_div[6]  = m_b0_0;
            m_b1_div[6]  = m_b1_0;
            m_b0_div[7]  = m_b0_2;
            m_b1_div[7]  = m_b1_2;
            m_b0_div[8]  = m_b0_1;
            m_b1_div[8]  = m_b1_1;
            m_b0_div[9]  = m_b0_3;
            m_b1_div[9]  = m_b1_3;
            m_b0_div[10] = m_b0_2;
            m_b1_div[10] = m_b1_2;
            m_b0_div[11] = m_b0_3;
            m_b1_div[11] = m_b1_3;
            modez_in[0]  = 3'd0;
            modez_in[1]  = 3'd6; //shift 16
            modez_in[2]  = 3'd7; //shift 8
            modez_in[3]  = 3'd7; //shift 8
            modez_in[4]  = 3'd7; //shift 8
            modez_in[5]  = 3'd7; //shift 8
            modez_in[6]  = 3'd3; //shift 0
            modez_in[7]  = 3'd7; //shift 8
            modez_in[8]  = 3'd7; //shift 8
            modez_in[9]  = 3'd7; //shift 8
            modez_in[10] = 3'd7; //shift 8
            modez_in[11] = 3'd6; //shift 16
        end
    end
end
endgenerate

genvar m_i;
generate
    for (m_i=0; m_i < GTP_APM_E2_NUM; m_i=m_i+1)
    begin:data_in
        always@(posedge clk or posedge rst_async)
        begin:inreg
            if (rst_async)
            begin
                m_a0_div_ff[m_i]  <= 25'b0;
                m_a1_div_ff[m_i]  <= 25'b0;
                m_b0_div_ff[m_i]  <= 18'b0;
                m_b1_div_ff[m_i]  <= 18'b0;
            end
            else if (rst_sync)
            begin
                m_a0_div_ff[m_i]  <= 25'b0;
                m_a1_div_ff[m_i]  <= 25'b0;
                m_b0_div_ff[m_i]  <= 18'b0;
                m_b1_div_ff[m_i]  <= 18'b0;
            end
            else if (ce)
            begin
                m_a0_div_ff[m_i]  <= m_a0_div[m_i];
                m_a1_div_ff[m_i]  <= m_a1_div[m_i];
                m_b0_div_ff[m_i]  <= m_b0_div[m_i];
                m_b1_div_ff[m_i]  <= m_b1_div[m_i];
            end
        end

        assign m_a0_in[m_i] = (INREG_EN == 1) ? m_a0_div_ff[m_i] : m_a0_div[m_i];
        assign m_a1_in[m_i] = (INREG_EN == 1) ? m_a1_div_ff[m_i] : m_a1_div[m_i];
        assign m_b0_in[m_i] = (INREG_EN == 1) ? m_b0_div_ff[m_i] : m_b0_div[m_i];
        assign m_b1_in[m_i] = (INREG_EN == 1) ? m_b1_div_ff[m_i] : m_b1_div[m_i];
    end
endgenerate

//************************************************************GTP*********************************************************
genvar i;
generate
    for (i=0; i< GTP_APM_E2_NUM; i=i+1)
    begin:multadd
    GTP_APM_E2 #(
        .GRS_EN         ( GRS_EN                 ) ,  //"TRUE","FALSE",enable global reset
        .USE_POSTADD    ( USE_POSTADD            ) ,  //enable postadder 0/1
        .USE_PREADD     ( 1'b0                   ) ,  //enable preadder 0/1
        .PREADD_REG     ( 1'b0                   ) ,  //preadder reg 0/1

        .X_REG          ( PIPEREG_EN_1           ) ,  //X input reg 0/1
        .CXO_REG        ( 2'b0                   ) ,  //X cascade out reg latency, 0/1/2/3
        .XB_REG         ( 1'b0                   ) ,  //XB input reg 0/1
        .Y_REG          ( PIPEREG_EN_1           ) ,  //Y input reg 0/1
        .Z_REG          ( PIPEREG_EN_1           ) ,  //Z input reg 0/1
        .MULT_REG       ( PIPEREG_EN_2           ) ,  //multiplier reg 0/1
        .P_REG          ( PIPEREG_EN_3           ) ,  //post adder reg 0/1
        .MODEY_REG      ( 1'b0                   ) ,  //MODEY reg
        .MODEZ_REG      ( PIPEREG_EN_1           ) ,  //MODEZ reg
        .MODEIN_REG     ( 1'b0                   ) ,  //MODEZ reg

        .X_SEL          ( 1'b0                   ) ,  // mult X input select X/CXI
        .XB_SEL         ( 2'b0                   ) ,  //X back propagate mux select. 0/1/2/3
        .ASYNC_RST      ( ASYNC_RST              ) ,  // RST is sync/async
        .USE_SIMD       ( USE_SIMD               ) ,  // single addsub25_mult25_add48 / dual addsub12_mult12_add24
        .P_INIT0        ( {48{1'b0}}             ) ,  //P constant input0 (RTI parameter in APM of PG family)
        .P_INIT1        ( {48{1'b0}}             ) ,  //P constant input1 (RTI parameter in APM of PG family)
        .ROUNDMODE_SEL  ( 1'b0                   ) ,  //round mode selection

        .CPO_REG        ( CPO_REG[i]             ) ,  // CPO,COUT use register output
        .USE_ACCLOW     ( 1'b0                   ) ,  // accumulator use lower 18-bit feedback only
        .CIN_SEL        ( 1'b0                   )    // select CIN for postadder carry in

    )
    multadd_0
    (
        .P         ( m_p[i]                 ) ,
        .CPO       ( cpo[(i+1)*2]           ) , //p cascade output
        .COUT      (                        ) ,
        .CXO       (                        ) , //x cascade output
        .CXBO      (                        ) , //x backward cascade output

        .X         ( {{5{1'b1}},m_a0_in[i]} ) ,
        .CXI       ( 30'b0                  ) , //x cascade input
        .CXBI      ( 25'b0                  ) , //x backward cascade input
        .XB        ( {25{1'b1}}             ) , //x backward cascade input
        .Y         ( m_b0_in[i]             ) ,
        .Z         ( {48{1'b1}}             ) ,
        .CPI       ( cpo[(i*2+1)]           ) , //p cascade input
        .CIN       ( 1'b0                   ) ,
        .MODEY     ( 3'b1                   ) ,
        .MODEZ     ( {addsub_in[i],3'b11}   ) ,
        .MODEIN    ( 5'b00010               ) ,

        .CLK       ( clk ) ,

        .CEX1      ( ce  ) , //X1 enable signals
        .CEX2      ( ce  ) , //X2 enable signals
        .CEX3      ( ce  ) , //X3 enable signals
        .CEXB      ( ce  ) , //XB enable signals
        .CEY1      ( ce  ) , //Y1 enable signals
        .CEY2      ( ce  ) , //Y2 enable signals
        .CEZ       ( ce  ) , //Z enable signals
        .CEPRE     ( ce  ) , //PRE enable signals
        .CEM       ( ce  ) , //M enable signals
        .CEP       ( ce  ) , //P enable signals
        .CEMODEY   ( ce  ) , //MODEY enable signals
        .CEMODEZ   ( ce  ) , //MODEZ enable signals
        .CEMODEIN  ( ce  ) , //MODEIN enable signals

        .RSTX      ( rst ) , //X reset signals
        .RSTXB     ( rst ) , //XB reset signals
        .RSTY      ( rst ) , //Y reset signals
        .RSTZ      ( rst ) , //Z reset signals
        .RSTPRE    ( rst ) , //PRE reset signals
        .RSTM      ( rst ) , //M reset signals
        .RSTP      ( rst ) , //P reset signals
        .RSTMODEY  ( rst ) , //MODEY reset signals
        .RSTMODEZ  ( rst ) , //MODEZ reset signals
        .RSTMODEIN ( rst )   //MODEIN reset signals

    );

    GTP_APM_E2 #(
        .GRS_EN         ( GRS_EN                 ) ,  //"TRUE","FALSE",enable global reset
        .USE_POSTADD    ( USE_POSTADD            ) ,  //enable postadder 0/1
        .USE_PREADD     ( 1'b0                   ) ,  //enable preadder 0/1
        .PREADD_REG     ( 1'b0                   ) ,  //preadder reg 0/1

        .X_REG          ( PIPEREG_EN_1           ) ,  //X input reg 0/1
        .CXO_REG        ( 2'b0                   ) ,  //X cascade out reg latency, 0/1/2/3
        .XB_REG         ( 1'b0                   ) ,  //XB input reg 0/1
        .Y_REG          ( PIPEREG_EN_1           ) ,  //Y input reg 0/1
        .Z_REG          ( PIPEREG_EN_1           ) ,  //Z input reg 0/1
        .MULT_REG       ( PIPEREG_EN_2           ) ,  //multiplier reg 0/1
        .P_REG          ( PIPEREG_EN_3           ) ,  //post adder reg 0/1
        .MODEY_REG      ( 1'b0                   ) ,  //MODEY reg
        .MODEZ_REG      ( PIPEREG_EN_1           ) ,  //MODEZ reg
        .MODEIN_REG     ( 1'b0                   ) ,  //MODEZ reg

        .X_SEL          ( 1'b0                   ) ,  // mult X input select X/CXI
        .XB_SEL         ( 2'b0                   ) ,  //X back propagate mux select. 0/1/2/3
        .ASYNC_RST      ( ASYNC_RST              ) ,  // RST is sync/async
        .USE_SIMD       ( USE_SIMD               ) ,  // single addsub25_mult25_add48 / dual addsub12_mult12_add24
        .P_INIT0        ( {48{1'b0}}             ) ,  //P constant input0 (RTI parameter in APM of PG family)
        .P_INIT1        ( {48{1'b0}}             ) ,  //P constant input1 (RTI parameter in APM of PG family)
        .ROUNDMODE_SEL  ( 1'b0                   ) ,  //round mode selection

        .CPO_REG        ( 1'b0                   ) ,  // CPO,COUT use register output
        .USE_ACCLOW     ( 1'b0                   ) ,  // accumulator use lower 18-bit feedback only
        .CIN_SEL        ( 1'b0                   )    // select CIN for postadder carry in

    )
    multadd_1
    (
        .P         (                           ) ,
        .CPO       ( cpo[(i*2+1)]              ) , //p cascade output
        .COUT      (                           ) ,
        .CXO       (                           ) , //x cascade output
        .CXBO      (                           ) , //x backward cascade output

        .X         ( {{5{1'b1}},m_a1_in[i]}    ) ,
        .CXI       ( 30'b0                     ) , //x cascade input
        .CXBI      ( 25'b0                     ) , //x backward cascade input
        .XB        ( {25{1'b1}}                ) , //x backward cascade input
        .Y         ( m_b1_in[i]                ) ,
        .Z         ( {48{1'b1}}                ) ,
        .CPI       ( cpo[i*2]                  ) , //p cascade input
        .CIN       ( 1'b0                      ) ,
        .MODEY     ( 3'b1                      ) ,
        .MODEZ     ( {addsub_in[i],modez_in[i]}) ,
        .MODEIN    ( 5'b00010                  ) ,

        .CLK       ( clk ) ,

        .CEX1      ( ce  ) , //X1 enable signals
        .CEX2      ( ce  ) , //X2 enable signals
        .CEX3      ( ce  ) , //X3 enable signals
        .CEXB      ( ce  ) , //XB enable signals
        .CEY1      ( ce  ) , //Y1 enable signals
        .CEY2      ( ce  ) , //Y2 enable signals
        .CEZ       ( ce  ) , //Z enable signals
        .CEPRE     ( ce  ) , //PRE enable signals
        .CEM       ( ce  ) , //M enable signals
        .CEP       ( ce  ) , //P enable signals
        .CEMODEY   ( ce  ) , //MODEY enable signals
        .CEMODEZ   ( ce  ) , //MODEZ enable signals
        .CEMODEIN  ( ce  ) , //MODEIN enable signals

        .RSTX      ( rst ) , //X reset signals
        .RSTXB     ( rst ) , //XB reset signals
        .RSTY      ( rst ) , //Y reset signals
        .RSTZ      ( rst ) , //Z reset signals
        .RSTPRE    ( rst ) , //PRE reset signals
        .RSTM      ( rst ) , //M reset signals
        .RSTP      ( rst ) , //P reset signals
        .RSTMODEY  ( rst ) , //MODEY reset signals
        .RSTMODEZ  ( rst ) , //MODEZ reset signals
        .RSTMODEIN ( rst )   //MODEIN reset signals

    );

    end
endgenerate


//*****************************************************************output***************************************************
 
generate
begin:outdata
    if (MAX_DATA_SIZE <= 12 && MIN_DATA_SIZE <= 9 )  //12x9
        assign m_p_o[21:0] = m_p[0][21:0];
    else if (MAX_DATA_SIZE <= 25 && MIN_DATA_SIZE <= 18)    //25x18
        assign m_p_o[43:0] = m_p[0][43:0];
    else if (MAX_DATA_SIZE <= 34 && MIN_DATA_SIZE <= 25)    //25x34
        assign m_p_o[59:0] = {m_p[1][43:0],m_p[0][15:0]};
    else if (MAX_DATA_SIZE <= 49 && MIN_DATA_SIZE <= 18)    //49x18
        assign m_p_o[67:0] = {m_p[1][43:0],m_p[0][23:0]};
    else if (MAX_DATA_SIZE <= 50 && MIN_DATA_SIZE <= 25)    //25x50
        assign m_p_o[75:0] = {m_p[2][43:0],m_p[1][15:0],m_p[0][15:0]};
    else if (MAX_DATA_SIZE <= 73 && MIN_DATA_SIZE <= 18)    //73x18
        assign m_p_o[91:0] = {m_p[2][43:0],m_p[1][23:0],m_p[0][23:0]};
    else if (MAX_DATA_SIZE <= 66 && MIN_DATA_SIZE <= 25)    //25x66
        assign m_p_o[91:0] = {m_p[3][43:0],m_p[2][15:0],m_p[1][15:0],m_p[0][15:0]};
    else if (MAX_DATA_SIZE <= 49 && MIN_DATA_SIZE <= 34)    //49x34
        assign m_p_o[83:0] = {m_p[3][43:0],m_p[2][15:0],m_p[1][7:0],m_p[0][15:0]};
    else if (MAX_DATA_SIZE <= 50 && MIN_DATA_SIZE <= 49)    //49x50
        assign m_p_o[99:0] = {m_p[5][43:0],m_p[4][15:0],m_p[3][7:0],m_p[2][7:0],m_p[1][7:0],m_p[0][15:0]};
    else if (MAX_DATA_SIZE <= 73 && MIN_DATA_SIZE <= 34)    //73x34
        assign m_p_o[107:0] = {m_p[5][43:0],m_p[4][15:0],m_p[3][7:0],m_p[2][15:0],m_p[1][7:0],m_p[0][15:0]};
    else if (MAX_DATA_SIZE <= 66 && MIN_DATA_SIZE <= 49)    //49x66
        assign m_p_o[115:0] = {m_p[7][43:0],m_p[6][15:0],m_p[5][7:0],m_p[4][7:0],m_p[3][7:0],m_p[2][7:0],m_p[1][7:0],m_p[0][15:0]};
    else if (MAX_DATA_SIZE <= 73 && MIN_DATA_SIZE <= 50)    //73x50
        assign m_p_o[123:0] = {m_p[8][43:0],m_p[7][15:0],m_p[6][7:0],m_p[5][7:0],m_p[4][7:0],m_p[3][7:0],m_p[2][7:0],m_p[1][7:0],m_p[0][15:0]};
    else if (MAX_DATA_SIZE <= 73 && MIN_DATA_SIZE <= 66)    //73x66
        assign m_p_o[139:0] = {m_p[11][43:0],m_p[10][15:0],m_p[9][7:0],m_p[8][7:0],m_p[7][7:0],m_p[6][7:0],m_p[4][7:0],m_p[3][7:0],m_p[2][7:0],m_p[1][7:0],m_p[0][15:0]};
end
endgenerate

//**************************************************************output reg***********************************************************
 
always@(posedge clk or posedge rst_async)
begin:outreg
    if (rst_async)
        m_p_o_ff <= 140'b0;
    else if (rst_sync)
        m_p_o_ff <= 140'b0;
    else if (ce)
        m_p_o_ff <= m_p_o;
end

assign p = (OUTREG_EN == 1) ? m_p_o_ff[PSIZE-1:0] : m_p_o[PSIZE-1:0];

endmodule
