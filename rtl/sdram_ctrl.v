`timescale 1ns/1ps
`default_nettype none

module sdram_ctrl #(
    // Address configuration
    parameter ROW_BITS  = 13,
    parameter COL_BITS  = 9,
    parameter BANK_BITS = 2,

    // Timing parameters (unit: SDRAM clock cycles)
    parameter integer T_INIT_100US = 10000, // ~100us @100MHz
    parameter integer T_RP         = 3,     // precharge time
    parameter integer T_RCD        = 3,     // ACT ? READ/WRITE
    parameter integer T_RFC        = 7,     // refresh cycle time
    parameter integer T_MRD        = 2,     // mode register set
    parameter integer T_WR         = 3,     // write recovery
    parameter integer T_REF_INT    = 7800,  // refresh interval
    parameter integer CL           = 3      // CAS latency (2 or 3)
)(
    input  wire                                    clk,
    input  wire                                    rst_n,

    // ---------- Host Command Interface ----------
    input  wire                                    cmd_valid,
    input  wire                                    cmd_write,
    input  wire [ROW_BITS+COL_BITS+BANK_BITS-1:0] cmd_addr,
    input  wire [15:0]                             cmd_wdata,
    input  wire                                    rsp_ready,  // Host ready to accept data
    output reg                                     cmd_ready,

    output reg                                     rsp_valid,
    output reg [15:0]                              rsp_rdata,

    // ---------- SDRAM Interface ----------
    output wire                                    sd_clk,
    output reg                                     sd_cke,
    output reg                                     sd_cs_n,
    output reg                                     sd_ras_n,
    output reg                                     sd_cas_n,
    output reg                                     sd_we_n,
    output reg [BANK_BITS-1:0]                     sd_ba,
    output reg [12:0]                              sd_addr,
    inout  wire [15:0]                             sd_dq,
    output reg [1:0]                               sd_dqm,

    // ---------- Status/Debug Interface ----------
    output reg                                     error_flag,
    output reg [4:0]                               state_out
);

    assign sd_clk = clk;

    localparam TOT_ADDR  = ROW_BITS + COL_BITS + BANK_BITS;
    localparam NUM_BANKS = (1 << BANK_BITS);

    // Command encoding {RAS,CAS,WE}
    localparam [2:0] CMD_NOP    = 3'b111;
    localparam [2:0] CMD_ACTIVE = 3'b011;
    localparam [2:0] CMD_READ   = 3'b101;
    localparam [2:0] CMD_WRITE  = 3'b100;
    localparam [2:0] CMD_PRECH  = 3'b010;
    localparam [2:0] CMD_REF    = 3'b001;
    localparam [2:0] CMD_MRS    = 3'b000;

    reg [2:0] cmd_code;

    // DQ tri-state
    reg [15:0] dq_out;
    reg        dq_oe;

    assign sd_dq = dq_oe ? dq_out : 16'hZZZZ;

    // ---------- Host command pipeline (Stage 1) ----------
    // *** FIX_STAGE2: ??ng ký l?i tín hi?u host ?? tránh race TB/DUT
    reg                   cmd_valid_r;
    reg                   cmd_write_r;
    reg [TOT_ADDR-1:0]    cmd_addr_r;
    reg [15:0]            cmd_wdata_r;

    // Address decomposition cho command m?i t? host (?ã qua Stage 1)
    // *** FIX_STAGE2: decode t? cmd_addr_r thay vì cmd_addr
    wire [BANK_BITS-1:0] new_bank =
        cmd_addr_r[BANK_BITS-1:0];

    wire [COL_BITS-1:0] new_col =
        cmd_addr_r[BANK_BITS+COL_BITS-1 : BANK_BITS];

    wire [ROW_BITS-1:0] new_row =
        cmd_addr_r[TOT_ADDR-1 : TOT_ADDR-ROW_BITS];

    // Latch host command (Stage 2)
    reg                  cmd_write_q;
    reg [TOT_ADDR-1:0]   cmd_addr_q;
    reg [15:0]           cmd_wdata_q;

    // Address decomposition cho command ?ang x? lý
    wire [BANK_BITS-1:0] cur_bank =
        cmd_addr_q[BANK_BITS-1:0];

    wire [COL_BITS-1:0] cur_col =
        cmd_addr_q[BANK_BITS+COL_BITS-1 : BANK_BITS];

    wire [ROW_BITS-1:0] cur_row =
        cmd_addr_q[TOT_ADDR-1 : TOT_ADDR-ROW_BITS];

    // FSM states
    localparam [4:0]
        S_RESET_START   = 5'd0,
        S_RESET_WAIT    = 5'd1,
        S_INIT_PRE      = 5'd2,
        S_INIT_PRE_WAIT = 5'd3,
        S_INIT_REF1     = 5'd4,
        S_INIT_REF1_WAIT= 5'd5,
        S_INIT_REF2     = 5'd6,
        S_INIT_REF2_WAIT= 5'd7,
        S_INIT_MRS      = 5'd8,
        S_INIT_MRS_WAIT = 5'd9,
        S_IDLE          = 5'd10,
        S_ACTIVATE      = 5'd11,
        S_ACT_WAIT      = 5'd12,
        S_READ_CMD      = 5'd13,
        S_CL_WAIT       = 5'd14,
        S_READ_DATA     = 5'd15,
        S_READ_DATA_HOLD= 5'd16,
        S_WRITE_CMD     = 5'd17,
        S_WRITE_RECOV   = 5'd18,
        S_READ_RECOV    = 5'd19,
        S_REFRESH_CMD   = 5'd20,
        S_REFRESH_WAIT  = 5'd21,
        S_ERROR         = 5'd22;

    reg [4:0] state, next_state;

    // Timer
    reg [15:0] timer;
    reg        timer_load;
    reg [15:0] timer_value;
    wire       timer_done = (timer == 16'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            timer <= 16'd0;
        end else begin
            if (timer_load)
                timer <= timer_value;
            else if (timer != 16'd0)
                timer <= timer - 16'd1;
        end
    end

    // Refresh interval counter
    reg [31:0] ref_cnt;
    reg        refresh_pending;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ref_cnt         <= 32'd0;
            refresh_pending <= 1'b0;
        end else begin
            // Reset refresh counter during initialization
            if (state == S_RESET_START ||
                state == S_RESET_WAIT  ||
                state == S_INIT_PRE    ||
                state == S_INIT_PRE_WAIT ||
                state == S_INIT_REF1   ||
                state == S_INIT_REF1_WAIT ||
                state == S_INIT_REF2   ||
                state == S_INIT_REF2_WAIT ||
                state == S_INIT_MRS    ||
                state == S_INIT_MRS_WAIT) begin
                ref_cnt         <= 32'd0;
                refresh_pending <= 1'b0;
            end else begin
                if (state == S_REFRESH_WAIT && timer_done) begin
                    refresh_pending <= 1'b0;
                    ref_cnt         <= 32'd0;
                end else if (!refresh_pending) begin
                    if (ref_cnt >= T_REF_INT) begin
                        refresh_pending <= 1'b1;
                        ref_cnt         <= 32'd0;
                    end else begin
                        ref_cnt <= ref_cnt + 32'd1;
                    end
                end
            end
        end
    end

    // Bank/Row active tracking
    reg [ROW_BITS-1:0]  active_row   [0:NUM_BANKS-1];
    reg [NUM_BANKS-1:0] bank_active;
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bank_active <= {NUM_BANKS{1'b0}};
            for (i = 0; i < NUM_BANKS; i = i + 1)
                active_row[i] <= {ROW_BITS{1'b0}};
        end else begin
            // Mark row active when ACT WAIT done
            if (state == S_ACT_WAIT && timer_done) begin
                bank_active[cur_bank] <= 1'b1;
                active_row[cur_bank]  <= cur_row;
            end

            // Clear flag when auto-precharge completes
            if ((state == S_READ_RECOV  && timer_done) ||
                (state == S_WRITE_RECOV && timer_done)) begin
                bank_active[cur_bank] <= 1'b0;
            end
        end
    end

    // *** FIX_STAGE2: Stage 1 - sample tín hi?u host
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmd_valid_r  <= 1'b0;
            cmd_write_r  <= 1'b0;
            cmd_addr_r   <= {TOT_ADDR{1'b0}};
            cmd_wdata_r  <= 16'd0;
        end else begin
            cmd_valid_r  <= cmd_valid;
            cmd_write_r  <= cmd_write;
            cmd_addr_r   <= cmd_addr;
            cmd_wdata_r  <= cmd_wdata;
        end
    end

    // Latch host command (Stage 2)
    // *** FIX_STAGE2: ch? latch ? IDLE, dùng giá tr? ?ã register
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmd_write_q  <= 1'b0;
            cmd_addr_q   <= {TOT_ADDR{1'b0}};
            cmd_wdata_q  <= 16'd0;
        end else begin
            if (state == S_IDLE && cmd_valid_r && cmd_ready) begin
                cmd_write_q <= cmd_write_r;
                cmd_addr_q  <= cmd_addr_r;
                cmd_wdata_q <= cmd_wdata_r;
            end
        end
    end

    // State register
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_RESET_START;
        end else begin
            state <= next_state;
        end
    end

    // Read data latch with hold capability
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rsp_rdata <= 16'd0;
            rsp_valid <= 1'b0;
        end else begin
            if (state == S_READ_DATA && !dq_oe) begin
                rsp_rdata <= sd_dq;
                rsp_valid <= 1'b1;
            end
            else if (rsp_valid && !rsp_ready) begin
                rsp_valid <= 1'b1;
            end
            else begin
                rsp_valid <= 1'b0;
            end
        end
    end

    // Error detection
    reg [15:0] idle_timeout;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            error_flag    <= 1'b0;
            idle_timeout  <= 16'd0;
        end else begin
            if (state == S_IDLE && !cmd_valid) begin
                if (idle_timeout < 16'hFFFF)
                    idle_timeout <= idle_timeout + 16'd1;
            end else begin
                idle_timeout <= 16'd0;
            end

            if (idle_timeout > 16'd100000 || state == S_ERROR) begin
                error_flag <= 1'b1;
            end
        end
    end

    // Debug: output current state
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state_out <= S_RESET_START;
        else
            state_out <= state;
    end

    // ---------- Combinational FSM + SDRAM signals ----------
    always @(*) begin
        next_state  = state;
        cmd_code    = CMD_NOP;

        sd_cke      = 1'b1;
        sd_cs_n     = 1'b0;
        sd_ba       = {BANK_BITS{1'b0}};
        sd_addr     = 13'd0;
        sd_dqm      = 2'b00;

        dq_oe       = 1'b0;
        dq_out      = 16'd0;

        cmd_ready   = 1'b0;

        timer_load  = 1'b0;
        timer_value = 16'd0;

        case (state)
            // ========== INITIALIZATION SEQUENCE ==========
            S_RESET_START: begin
                sd_cke      = 1'b0;
                cmd_code    = CMD_NOP;
                timer_load  = 1'b1;
                timer_value = T_INIT_100US[15:0];
                next_state  = S_RESET_WAIT;
            end

            S_RESET_WAIT: begin
                sd_cke   = 1'b0;
                cmd_code = CMD_NOP;
                if (timer_done) begin
                    next_state = S_INIT_PRE;
                end
            end

            S_INIT_PRE: begin
                sd_cke      = 1'b1;
                cmd_code    = CMD_PRECH;
                sd_addr[10] = 1'b1;  // precharge all
                timer_load  = 1'b1;
                timer_value = T_RP[15:0];
                next_state  = S_INIT_PRE_WAIT;
            end

            S_INIT_PRE_WAIT: begin
                cmd_code = CMD_NOP;
                if (timer_done) begin
                    next_state = S_INIT_REF1;
                end
            end

            S_INIT_REF1: begin
                cmd_code    = CMD_REF;
                timer_load  = 1'b1;
                timer_value = T_RFC[15:0];
                next_state  = S_INIT_REF1_WAIT;
            end

            S_INIT_REF1_WAIT: begin
                cmd_code = CMD_NOP;
                if (timer_done) begin
                    next_state = S_INIT_REF2;
                end
            end

            S_INIT_REF2: begin
                cmd_code    = CMD_REF;
                timer_load  = 1'b1;
                timer_value = T_RFC[15:0];
                next_state  = S_INIT_REF2_WAIT;
            end

            S_INIT_REF2_WAIT: begin
                cmd_code = CMD_NOP;
                if (timer_done) begin
                    next_state = S_INIT_MRS;
                end
            end

            S_INIT_MRS: begin
                cmd_code      = CMD_MRS;
                sd_addr[11:0] = {3'b000, 1'b0, 3'b000, CL[2:0], 1'b0, 3'b000};
                timer_load    = 1'b1;
                timer_value   = T_MRD[15:0];
                next_state    = S_INIT_MRS_WAIT;
            end

            S_INIT_MRS_WAIT: begin
                cmd_code = CMD_NOP;
                if (timer_done) begin
                    next_state = S_IDLE;
                end
            end

            // ========== IDLE + REFRESH ==========
            S_IDLE: begin
                cmd_code  = CMD_NOP;
                cmd_ready = (!refresh_pending);

                if (refresh_pending) begin
                    next_state = S_REFRESH_CMD;
                end else if (cmd_valid_r && cmd_ready) begin   // *** FIX_STAGE2: dùng cmd_valid_r
                    if (bank_active[new_bank] && active_row[new_bank] == new_row) begin
                        // *** FIX_STAGE2: dùng cmd_write_r ?? ch?n RW khi row-hit
                        if (cmd_write_r)
                            next_state = S_WRITE_CMD;
                        else
                            next_state = S_READ_CMD;
                    end else begin
                        cmd_code    = CMD_ACTIVE;
                        sd_ba       = new_bank;
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
                    next_state = S_IDLE;
                end
            end

            // ========== READ/WRITE SEQUENCE ==========
            S_ACT_WAIT: begin
                cmd_code = CMD_NOP;
                if (timer_done) begin
                    if (cmd_write_q)
                        next_state = S_WRITE_CMD;
                    else
                        next_state = S_READ_CMD;
                end
            end

            S_READ_CMD: begin
                cmd_code  = CMD_READ;
                sd_ba     = cur_bank;
                sd_addr[COL_BITS-1:0] = cur_col;
                sd_addr[10]           = 1'b1;  // auto-precharge

                timer_load  = 1'b1;
                timer_value = (CL >= 2) ? CL[15:0] : 16'd2;
                next_state  = S_CL_WAIT;
            end

            S_CL_WAIT: begin
                cmd_code = CMD_NOP;
                if (timer_done) begin
                    next_state = S_READ_DATA;
                end
            end

            S_READ_DATA: begin
                cmd_code   = CMD_NOP;
                next_state = S_READ_DATA_HOLD;
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
                    next_state = S_IDLE;
                end
            end

            S_WRITE_CMD: begin
                cmd_code  = CMD_WRITE;
                sd_ba     = cur_bank;
                sd_addr[COL_BITS-1:0] = cur_col;
                sd_addr[10]           = 1'b1;
                dq_oe                 = 1'b1;
                dq_out                = cmd_wdata_q;

                timer_load  = 1'b1;
                if ((T_WR + T_RP) > 16'hFFFF)
                    timer_value = 16'hFFFF;
                else
                    timer_value = T_WR + T_RP;
                next_state  = S_WRITE_RECOV;
            end

            S_WRITE_RECOV: begin
                cmd_code = CMD_NOP;
                if (timer_done) begin
                    next_state = S_IDLE;
                end
            end

            S_ERROR: begin
                cmd_code   = CMD_NOP;
                cmd_ready  = 1'b0;
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
