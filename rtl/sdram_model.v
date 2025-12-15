`timescale 1ns/1ps
`default_nettype none

module sdram_model #(
    parameter ROW_BITS  = 13,
    parameter COL_BITS  = 9,
    parameter BANK_BITS = 2,
    // *** CL_FIX: thêm tham s? CAS latency (s? chu k? clock)
    parameter integer CL_CYCLES = 3
)(
    input  wire                   clk,
    input  wire                   cke,
    input  wire                   cs_n,
    input  wire                   ras_n,
    input  wire                   cas_n,
    input  wire                   we_n,
    input  wire [BANK_BITS-1:0]   ba,
    input  wire [12:0]            addr,
    inout  wire [15:0]            dq,
    input  wire [1:0]             dqm
);

    // Command encoding
    localparam [2:0]
        CMD_NOP    = 3'b111,
        CMD_ACTIVE = 3'b011,
        CMD_READ   = 3'b101,
        CMD_WRITE  = 3'b100,
        CMD_PRECH  = 3'b010,
        CMD_REF    = 3'b001,
        CMD_MRS    = 3'b000;

    wire [2:0] cmd = {ras_n, cas_n, we_n};

    // Gi?m kích th??c RAM cho mô ph?ng
    localparam SIM_BANKS = 4;
    localparam SIM_ROWS  = 256;
    localparam SIM_COLS  = 256;
    localparam SIM_DEPTH = SIM_BANKS * SIM_ROWS * SIM_COLS;

    reg [15:0] mem [0:SIM_DEPTH-1];

    // Row ?ang open cho m?i bank
    reg [ROW_BITS-1:0] open_row [0:SIM_BANKS-1];
    reg                row_open [0:SIM_BANKS-1];

    // Tri-state DQ
    reg [15:0] dq_out;
    reg        dq_oe;

    assign dq = dq_oe ? dq_out : 16'hZZZZ;

    // Hàm tính ??a ch? linear t? (bank,row,col)
    function integer linear_addr;
        input integer bank_i;
        input integer row_i;
        input integer col_i;
        begin
            linear_addr = ((bank_i * SIM_ROWS) + row_i) * SIM_COLS + col_i;
        end
    endfunction

    integer i;
    integer bank_i, row_i, col_i, idx;

    // *** CL_FIX: pipeline cho READ v?i CAS latency
    reg        rd_pending;        // ?ang ch? tr? data cho m?t l?nh READ
    integer    rd_cnt;            // b? ??m CL
    integer    rd_bank, rd_row, rd_col;  // ??a ch? latch l?i t?i l?nh READ

    initial begin
        for (i = 0; i < SIM_DEPTH; i = i + 1)
            mem[i] = 16'h0000;

        for (i = 0; i < SIM_BANKS; i = i + 1) begin
            row_open[i] = 1'b0;
            open_row[i] = {ROW_BITS{1'b0}};
        end

        dq_out    = 16'h0000;
        dq_oe     = 1'b0;
        rd_pending = 1'b0;
        rd_cnt     = 0;
        rd_bank    = 0;
        rd_row     = 0;
        rd_col     = 0;
    end

    always @(posedge clk) begin
        // N?u chip không enable thì tri-state và clear pending
        if (cs_n || !cke) begin
            dq_oe      <= 1'b0;
            rd_pending <= 1'b0;   // *** CL_FIX: h?y m?i READ ?ang ch?
            rd_cnt     <= 0;
        end else begin
            // ---------- X? lý command ----------
            case (cmd)
                CMD_ACTIVE: begin
                    if (ba < SIM_BANKS) begin
                        open_row[ba] <= addr[ROW_BITS-1:0];
                        row_open[ba] <= 1'b1;
                    end
                    // Khi ACT row m?i thì ch?c ch?n không lái DQ
                    dq_oe <= 1'b0;
                end

                CMD_READ: begin
                    if (ba < SIM_BANKS && row_open[ba]) begin
                        // *** CL_FIX: Latch thông tin READ, KHÔNG lái dq ngay
                        bank_i = ba;
                        row_i  = open_row[ba];
                        col_i  = addr[COL_BITS-1:0];

                        // Gi?i h?n vào vùng mô ph?ng
                        row_i = row_i % SIM_ROWS;
                        col_i = col_i % SIM_COLS;

                        rd_bank    <= bank_i;
                        rd_row     <= row_i;
                        rd_col     <= col_i;
                        rd_cnt     <= CL_CYCLES; // ??m CL chu k?
                        rd_pending <= 1'b1;
                        dq_oe      <= 1'b0;      // CH?A lái bus ngay

                        // H? tr? auto-precharge (A10=1)
                        if (addr[10]) begin
                            row_open[ba] <= 1'b0;
                        end
                    end else begin
                        // N?u row ch?a open thì không lái gì, không pending
                        rd_pending <= 1'b0;
                        rd_cnt     <= 0;
                        dq_oe      <= 1'b0;
                    end
                end

                CMD_WRITE: begin
                    // ??m b?o model KHÔNG lái bus khi ?ang ghi
                    dq_oe <= 1'b0;

                    if (ba < SIM_BANKS && row_open[ba]) begin
                        bank_i = ba;
                        row_i  = open_row[ba];
                        col_i  = addr[COL_BITS-1:0];

                        // Gi?i h?n vào vùng mô ph?ng
                        row_i = row_i % SIM_ROWS;
                        col_i = col_i % SIM_COLS;

                        idx       = linear_addr(bank_i, row_i, col_i);
                        mem[idx] <= dq;   // ??c data t? controller

                        // auto-precharge cho WRITE n?u A10=1
                        if (addr[10]) begin
                            row_open[ba] <= 1'b0;
                        end
                    end
                    // WRITE không liên quan t?i rd_pending, ?? nguyên rd_pending/rd_cnt
                end

                CMD_PRECH: begin
                    // A10=1 -> precharge all
                    if (addr[10]) begin
                        for (i = 0; i < SIM_BANKS; i = i + 1)
                            row_open[i] <= 1'b0;
                    end else begin
                        if (ba < SIM_BANKS)
                            row_open[ba] <= 1'b0;
                    end
                    // Khi precharge, thôi không lái DQ n?a
                    dq_oe      <= 1'b0;
                    // *** CL_FIX: có th? h?y READ pending n?u mu?n ch?t ch?
                    // rd_pending <= 1'b0;
                    // rd_cnt     <= 0;
                end

                CMD_REF: begin
                    // Không làm gì, ch? gi? l?p refresh; c?ng không lái DQ
                    dq_oe <= 1'b0;
                    // *** CL_FIX: không ??ng t?i rd_pending, coi nh? DRAM gi? d? li?u n?i
                end

                CMD_MRS: begin
                    // Không dùng trong model ??n gi?n; không lái DQ
                    dq_oe      <= 1'b0;
                    // Không thay ??i rd_pending
                end

                default: begin
                    // NOP: gi? nguyên dq_oe, dq_out
                    // -> cho phép data gi? nguyên sau READ trong các chu k? NOP
                end
            endcase

            // ---------- Pipeline READ v?i CAS latency ----------
            if (rd_pending) begin
                if (rd_cnt > 0) begin
                    rd_cnt <= rd_cnt - 1;
                    // Khi v?a ??m xong (rd_cnt == 1 tr??c ?ó), cycle này tr? data
                    if (rd_cnt == 1) begin
                        // Tính index t? rd_bank/rd_row/rd_col ?ã latch
                        row_i = rd_row % SIM_ROWS;
                        col_i = rd_col % SIM_COLS;
                        idx   = linear_addr(rd_bank, row_i, col_i);

                        dq_out <= mem[idx];
                        dq_oe  <= 1'b1;   // b?t ??u lái data lên bus
                        // rd_pending v?n =1, dq_oe gi? t?i khi command khác clear
                    end
                end
            end
        end
    end

endmodule

`default_nettype wire
