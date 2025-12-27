`timescale 1ns/1ps
`default_nettype none

module sdram_fsm #(
    parameter ROW_BITS  = 13,
    parameter COL_BITS  = 9,
    parameter BANK_BITS = 2,

    parameter integer T_INIT_100US = 10000,
    parameter integer T_RP         = 3,
    parameter integer T_RCD        = 3,
    parameter integer T_RFC        = 7,
    parameter integer T_MRD        = 2,
    parameter integer T_WR         = 3,
    parameter integer CL           = 3
)(
    input  wire clk,
    input  wire rst_n,

    input  wire timer_done,
    input  wire refresh_pending,

    // stage-R command (stable, avoids TB race)
    input  wire        cmd_valid_r,
    input  wire        cmd_write_r,
    input  wire [BANK_BITS-1:0] new_bank,
    input  wire [COL_BITS-1:0]  new_col,
    input  wire [ROW_BITS-1:0]  new_row,

    // stage-Q command (latched accepted cmd)
    input  wire        cmd_write_q,
    input  wire [BANK_BITS-1:0] cur_bank,
    input  wire [COL_BITS-1:0]  cur_col,
    input  wire [ROW_BITS-1:0]  cur_row,
    input  wire [15:0]          cur_wdata,

    input  wire row_hit,
    input  wire rsp_valid,
    input  wire rsp_ready,

    output reg  [4:0] state_out,

    output reg        timer_load,
    output reg [15:0] timer_value,

    output reg        in_init,
    output reg        refresh_clear_pulse,

    // pulse to latch cmd_q in cmd_pipe
    output reg        accept_q_pulse,

    output reg        set_active_pulse,
    output reg [BANK_BITS-1:0] set_bank,
    output reg [ROW_BITS-1:0]  set_row,

    output reg        clear_active_pulse,
    output reg [BANK_BITS-1:0] clear_bank,

    output reg        rsp_capture_pulse,

    output reg        cmd_ready,

    // SDRAM bus
    output reg        sd_cke,
    output reg        sd_cs_n,
    output reg        sd_ras_n,
    output reg        sd_cas_n,
    output reg        sd_we_n,
    output reg [BANK_BITS-1:0] sd_ba,
    output reg [12:0] sd_addr,
    output reg [1:0]  sd_dqm,

    // DQ drive
    output reg        dq_oe,
    output reg [15:0] dq_out
);
    // {RAS,CAS,WE}
    localparam [2:0] CMD_NOP    = 3'b111;
    localparam [2:0] CMD_ACTIVE = 3'b011;
    localparam [2:0] CMD_READ   = 3'b101;
    localparam [2:0] CMD_WRITE  = 3'b100;
    localparam [2:0] CMD_PRECH  = 3'b010;
    localparam [2:0] CMD_REF    = 3'b001;
    localparam [2:0] CMD_MRS    = 3'b000;

    reg [2:0] cmd_code;

    localparam [4:0]
        S_RESET_START    = 5'd0,
        S_RESET_WAIT     = 5'd1,
        S_INIT_PRE       = 5'd2,
        S_INIT_PRE_WAIT  = 5'd3,
        S_INIT_REF1      = 5'd4,
        S_INIT_REF1_WAIT = 5'd5,
        S_INIT_REF2      = 5'd6,
        S_INIT_REF2_WAIT = 5'd7,
        S_INIT_MRS       = 5'd8,
        S_INIT_MRS_WAIT  = 5'd9,
        S_IDLE           = 5'd10,
        S_ACT_WAIT       = 5'd12,
        S_READ_CMD       = 5'd13,
        S_CL_WAIT        = 5'd14,
        S_READ_DATA      = 5'd15,
        S_READ_DATA_HOLD = 5'd16,
        S_WRITE_CMD      = 5'd17,
        S_WRITE_RECOV    = 5'd18,
        S_READ_RECOV     = 5'd19,
        S_REFRESH_CMD    = 5'd20,
        S_REFRESH_WAIT   = 5'd21,
        S_ERROR          = 5'd22;

    reg [4:0] state, next_state;
    integer sum_wr_rp;
    // state register
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_RESET_START;
        else        state <= next_state;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state_out <= S_RESET_START;
        else        state_out <= state;
    end

    // combinational outputs / next_state
    always @(*) begin
        next_state = state;
        cmd_code   = CMD_NOP;

        // defaults bus
        sd_cke  = 1'b1;
        sd_cs_n = 1'b0;
        sd_ba   = {BANK_BITS{1'b0}};
        sd_addr = 13'd0;
        sd_dqm  = 2'b00;

        // defaults dq
        dq_oe  = 1'b0;
        dq_out = 16'd0;

        // defaults control
        cmd_ready          = 1'b0;
        timer_load         = 1'b0;
        timer_value        = 16'd0;

        in_init            = 1'b0;
        refresh_clear_pulse= 1'b0;

        accept_q_pulse     = 1'b0;

        set_active_pulse   = 1'b0;
        set_bank           = {BANK_BITS{1'b0}};
        set_row            = {ROW_BITS{1'b0}};

        clear_active_pulse = 1'b0;
        clear_bank         = {BANK_BITS{1'b0}};

        rsp_capture_pulse  = 1'b0;

        case (state)
            S_RESET_START: begin
                in_init    = 1'b1;
                sd_cke     = 1'b0;
                cmd_code   = CMD_NOP;
                timer_load  = 1'b1;
                timer_value = T_INIT_100US[15:0];
                next_state  = S_RESET_WAIT;
            end

            S_RESET_WAIT: begin
                in_init  = 1'b1;
                sd_cke   = 1'b0;
                cmd_code = CMD_NOP;
                if (timer_done) next_state = S_INIT_PRE;
            end

            S_INIT_PRE: begin
                in_init     = 1'b1;
                cmd_code    = CMD_PRECH;
                sd_addr[10] = 1'b1;
                timer_load  = 1'b1;
                timer_value = T_RP[15:0];
                next_state  = S_INIT_PRE_WAIT;
            end

            S_INIT_PRE_WAIT: begin
                in_init  = 1'b1;
                cmd_code = CMD_NOP;
                if (timer_done) next_state = S_INIT_REF1;
            end

            S_INIT_REF1: begin
                in_init     = 1'b1;
                cmd_code    = CMD_REF;
                timer_load  = 1'b1;
                timer_value = T_RFC[15:0];
                next_state  = S_INIT_REF1_WAIT;
            end

            S_INIT_REF1_WAIT: begin
                in_init  = 1'b1;
                cmd_code = CMD_NOP;
                if (timer_done) next_state = S_INIT_REF2;
            end

            S_INIT_REF2: begin
                in_init     = 1'b1;
                cmd_code    = CMD_REF;
                timer_load  = 1'b1;
                timer_value = T_RFC[15:0];
                next_state  = S_INIT_REF2_WAIT;
            end

            S_INIT_REF2_WAIT: begin
                in_init  = 1'b1;
                cmd_code = CMD_NOP;
                if (timer_done) next_state = S_INIT_MRS;
            end

            S_INIT_MRS: begin
                in_init      = 1'b1;
                cmd_code     = CMD_MRS;
                sd_addr[11:0]= {3'b000, 1'b0, 3'b000, CL[2:0], 1'b0, 3'b000};
                timer_load   = 1'b1;
                timer_value  = T_MRD[15:0];
                next_state   = S_INIT_MRS_WAIT;
            end

            S_INIT_MRS_WAIT: begin
                in_init  = 1'b1;
                cmd_code = CMD_NOP;
                if (timer_done) next_state = S_IDLE;
            end

            S_IDLE: begin
                cmd_code  = CMD_NOP;
                cmd_ready = (!refresh_pending);

                if (refresh_pending) begin
                    next_state = S_REFRESH_CMD;
                end else if (cmd_valid_r && cmd_ready) begin
                    // accept this cmd (latch into Q at next posedge)
                    accept_q_pulse = 1'b1;

                    // row hit -> go directly to read/write cmd state (issued next cycle)
                    if (row_hit) begin
                        next_state = (cmd_write_r) ? S_WRITE_CMD : S_READ_CMD;
                    end else begin
                        // row miss -> issue ACTIVE immediately in IDLE (Mealy like original)
                        cmd_code = CMD_ACTIVE;
                        sd_ba    = new_bank;
                        sd_addr[ROW_BITS-1:0] = new_row;

                        timer_load  = 1'b1;
                        timer_value = T_RCD[15:0];
                        next_state  = S_ACT_WAIT;
                    end
                end
            end

            S_REFRESH_CMD: begin
                cmd_code    = CMD_REF;
                timer_load  = 1'b1;
                timer_value = T_RFC[15:0];
                next_state  = S_REFRESH_WAIT;
            end

            S_REFRESH_WAIT: begin
                cmd_code = CMD_NOP;
                if (timer_done) begin
                    refresh_clear_pulse = 1'b1;
                    next_state = S_IDLE;
                end
            end

            S_ACT_WAIT: begin
                cmd_code = CMD_NOP;
                if (timer_done) begin
                    set_active_pulse = 1'b1;
                    set_bank = cur_bank;
                    set_row  = cur_row;
                    next_state = (cmd_write_q) ? S_WRITE_CMD : S_READ_CMD;
                end
            end

            S_READ_CMD: begin
                cmd_code = CMD_READ;
                sd_ba    = cur_bank;
                sd_addr[COL_BITS-1:0] = cur_col;
                sd_addr[10] = 1'b1; // AP=1

                timer_load  = 1'b1;
                timer_value = (CL >= 2) ? CL[15:0] : 16'd2;
                next_state  = S_CL_WAIT;
            end

            S_CL_WAIT: begin
                cmd_code = CMD_NOP;
                if (timer_done) next_state = S_READ_DATA;
            end

            S_READ_DATA: begin
                cmd_code          = CMD_NOP;
                rsp_capture_pulse = 1'b1;
                next_state        = S_READ_DATA_HOLD;
            end

            S_READ_DATA_HOLD: begin
                cmd_code = CMD_NOP;
                if (rsp_valid && rsp_ready) begin
                    timer_load  = 1'b1;
                    timer_value = T_RP[15:0];
                    next_state  = S_READ_RECOV;
                end
            end

            S_READ_RECOV: begin
                cmd_code = CMD_NOP;
                if (timer_done) begin
                    clear_active_pulse = 1'b1;
                    clear_bank = cur_bank;
                    next_state = S_IDLE;
                end
            end

            S_WRITE_CMD: begin
                
                sum_wr_rp = T_WR + T_RP;

                cmd_code = CMD_WRITE;
                sd_ba    = cur_bank;
                sd_addr[COL_BITS-1:0] = cur_col;
                sd_addr[10] = 1'b1; // AP=1

                // IMPORTANT: drive dq in SAME cycle as WRITE cmd
                dq_oe  = 1'b1;
                dq_out = cur_wdata;

                timer_load = 1'b1;
                if (sum_wr_rp > 16'hFFFF) timer_value = 16'hFFFF;
                else                      timer_value = sum_wr_rp[15:0];

                next_state = S_WRITE_RECOV;
            end

            S_WRITE_RECOV: begin
                cmd_code = CMD_NOP;
                if (timer_done) begin
                    clear_active_pulse = 1'b1;
                    clear_bank = cur_bank;
                    next_state = S_IDLE;
                end
            end

            S_ERROR: begin
                cmd_code  = CMD_NOP;
                cmd_ready = 1'b0;
                next_state = S_ERROR;
            end

            default: begin
                next_state = S_RESET_START;
            end
        endcase

        {sd_ras_n, sd_cas_n, sd_we_n} = cmd_code;
    end
endmodule

`default_nettype wire
