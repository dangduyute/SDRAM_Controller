`timescale 1ns/1ps
`default_nettype none

module sdram_ctrl #(
    parameter ROW_BITS  = 13,
    parameter COL_BITS  = 9,
    parameter BANK_BITS = 2,

    parameter integer T_INIT_100US = 10000,
    parameter integer T_RP         = 3,
    parameter integer T_RCD        = 3,
    parameter integer T_RFC        = 7,
    parameter integer T_MRD        = 2,
    parameter integer T_WR         = 3,
    parameter integer T_REF_INT    = 7800,
    parameter integer CL           = 3
)(
    input  wire                                    clk,
    input  wire                                    rst_n,

    input  wire                                    cmd_valid,
    input  wire                                    cmd_write,
    input  wire [ROW_BITS+COL_BITS+BANK_BITS-1:0]  cmd_addr,
    input  wire [15:0]                             cmd_wdata,
    input  wire                                    rsp_ready,
    output wire                                    cmd_ready,

    output wire                                    rsp_valid,
    output wire [15:0]                             rsp_rdata,

    output wire                                    sd_clk,
    output wire                                    sd_cke,
    output wire                                    sd_cs_n,
    output wire                                    sd_ras_n,
    output wire                                    sd_cas_n,
    output wire                                    sd_we_n,
    output wire [BANK_BITS-1:0]                    sd_ba,
    output wire [12:0]                             sd_addr,
    inout  wire [15:0]                             sd_dq,
    output wire [1:0]                              sd_dqm,

    output wire                                    error_flag,
    output wire [4:0]                              state_out
);
    assign sd_clk = clk;

    localparam TOT_ADDR = ROW_BITS + COL_BITS + BANK_BITS;

    // dq tristate
    wire [15:0] dq_out_w;
    wire        dq_oe_w;
    assign sd_dq = dq_oe_w ? dq_out_w : 16'hZZZZ;

    // timer
    wire        timer_done;
    wire        timer_load;
    wire [15:0] timer_value;

    sdram_timer u_timer (
        .clk   (clk),
        .rst_n (rst_n),
        .load  (timer_load),
        .value (timer_value),
        .done  (timer_done)
    );

    // refresh
    wire in_init;
    wire refresh_clear_pulse;
    wire refresh_pending;

    sdram_refresh_counter #(
        .T_REF_INT(T_REF_INT)
    ) u_refresh (
        .clk                (clk),
        .rst_n              (rst_n),
        .in_init            (in_init),
        .refresh_clear_pulse(refresh_clear_pulse),
        .refresh_pending    (refresh_pending)
    );

    // cmd pipe
    wire cmd_valid_r, cmd_write_r;
    wire [TOT_ADDR-1:0] cmd_addr_r;
    wire [15:0] cmd_wdata_r;

    wire cmd_write_q;
    wire [TOT_ADDR-1:0] cmd_addr_q;
    wire [15:0] cmd_wdata_q;

    wire accept_q_pulse;

    sdram_cmd_pipe #(
        .ROW_BITS (ROW_BITS),
        .COL_BITS (COL_BITS),
        .BANK_BITS(BANK_BITS)
    ) u_pipe (
        .clk           (clk),
        .rst_n         (rst_n),
        .cmd_valid     (cmd_valid),
        .cmd_write     (cmd_write),
        .cmd_addr      (cmd_addr),
        .cmd_wdata     (cmd_wdata),
        .accept_q_pulse(accept_q_pulse),

        .cmd_valid_r   (cmd_valid_r),
        .cmd_write_r   (cmd_write_r),
        .cmd_addr_r    (cmd_addr_r),
        .cmd_wdata_r   (cmd_wdata_r),

        .cmd_write_q   (cmd_write_q),
        .cmd_addr_q    (cmd_addr_q),
        .cmd_wdata_q   (cmd_wdata_q)
    );

    // decode new/cur from R/Q
    wire [BANK_BITS-1:0] new_bank = cmd_addr_r[BANK_BITS-1:0];
    wire [COL_BITS-1:0]  new_col  = cmd_addr_r[BANK_BITS+COL_BITS-1 : BANK_BITS];
    wire [ROW_BITS-1:0]  new_row  = cmd_addr_r[TOT_ADDR-1 : TOT_ADDR-ROW_BITS];

    wire [BANK_BITS-1:0] cur_bank = cmd_addr_q[BANK_BITS-1:0];
    wire [COL_BITS-1:0]  cur_col  = cmd_addr_q[BANK_BITS+COL_BITS-1 : BANK_BITS];
    wire [ROW_BITS-1:0]  cur_row  = cmd_addr_q[TOT_ADDR-1 : TOT_ADDR-ROW_BITS];

    // bank tracker
    wire row_hit;
    wire set_active_pulse, clear_active_pulse;
    wire [BANK_BITS-1:0] set_bank, clear_bank;
    wire [ROW_BITS-1:0]  set_row;

    sdram_bank_tracker #(
        .ROW_BITS (ROW_BITS),
        .BANK_BITS(BANK_BITS)
    ) u_bank (
        .clk               (clk),
        .rst_n             (rst_n),

        .set_active_pulse  (set_active_pulse),
        .set_bank          (set_bank),
        .set_row           (set_row),

        .clear_active_pulse(clear_active_pulse),
        .clear_bank        (clear_bank),

        .query_bank        (new_bank),
        .query_row         (new_row),
        .row_hit           (row_hit)
    );

    // response capture
    wire rsp_capture_pulse;

    sdram_rsp_capture u_rsp (
        .clk          (clk),
        .rst_n        (rst_n),
        .capture_pulse(rsp_capture_pulse),
        .dq_in        (sd_dq),
        .rsp_ready    (rsp_ready),
        .rsp_valid    (rsp_valid),
        .rsp_rdata    (rsp_rdata)
    );

    // FSM
    sdram_fsm #(
        .ROW_BITS     (ROW_BITS),
        .COL_BITS     (COL_BITS),
        .BANK_BITS    (BANK_BITS),
        .T_INIT_100US (T_INIT_100US),
        .T_RP         (T_RP),
        .T_RCD        (T_RCD),
        .T_RFC        (T_RFC),
        .T_MRD        (T_MRD),
        .T_WR         (T_WR),
        .CL           (CL)
    ) u_fsm (
        .clk              (clk),
        .rst_n            (rst_n),

        .timer_done       (timer_done),
        .refresh_pending  (refresh_pending),

        .cmd_valid_r      (cmd_valid_r),
        .cmd_write_r      (cmd_write_r),
        .new_bank         (new_bank),
        .new_col          (new_col),
        .new_row          (new_row),

        .cmd_write_q      (cmd_write_q),
        .cur_bank         (cur_bank),
        .cur_col          (cur_col),
        .cur_row          (cur_row),
        .cur_wdata        (cmd_wdata_q),

        .row_hit          (row_hit),
        .rsp_valid        (rsp_valid),
        .rsp_ready        (rsp_ready),

        .state_out        (state_out),

        .timer_load       (timer_load),
        .timer_value      (timer_value),

        .in_init          (in_init),
        .refresh_clear_pulse(refresh_clear_pulse),

        .accept_q_pulse   (accept_q_pulse),

        .set_active_pulse (set_active_pulse),
        .set_bank         (set_bank),
        .set_row          (set_row),

        .clear_active_pulse(clear_active_pulse),
        .clear_bank       (clear_bank),

        .rsp_capture_pulse(rsp_capture_pulse),

        .cmd_ready        (cmd_ready),

        .sd_cke           (sd_cke),
        .sd_cs_n          (sd_cs_n),
        .sd_ras_n         (sd_ras_n),
        .sd_cas_n         (sd_cas_n),
        .sd_we_n          (sd_we_n),
        .sd_ba            (sd_ba),
        .sd_addr          (sd_addr),
        .sd_dqm           (sd_dqm),

        .dq_oe            (dq_oe_w),
        .dq_out           (dq_out_w)
    );

    // error_flag (watchdog)
    wire in_idle  = (state_out == 5'd10);
    wire in_error = (state_out == 5'd22);

    sdram_watchdog #(
        .IDLE_THRESH(100000)
    ) u_wd (
        .clk           (clk),
        .rst_n         (rst_n),
        .in_idle       (in_idle),
        .cmd_valid_raw (cmd_valid),
        .in_error_state(in_error),
        .error_flag    (error_flag)
    );

endmodule

`default_nettype wire
