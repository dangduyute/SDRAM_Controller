`timescale 1ns/1ps
`default_nettype none

module sdram_model #(
    parameter ROW_BITS  = 13,
    parameter COL_BITS  = 9,
    parameter BANK_BITS = 2,
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

    localparam [2:0]
        CMD_NOP    = 3'b111,
        CMD_ACTIVE = 3'b011,
        CMD_READ   = 3'b101,
        CMD_WRITE  = 3'b100,
        CMD_PRECH  = 3'b010,
        CMD_REF    = 3'b001,
        CMD_MRS    = 3'b000;

    wire [2:0] cmd = {ras_n, cas_n, we_n};

    localparam SIM_BANKS = 4;
    localparam SIM_ROWS  = 256;
    localparam SIM_COLS  = 256;
    localparam SIM_DEPTH = SIM_BANKS * SIM_ROWS * SIM_COLS;

    reg [15:0] mem [0:SIM_DEPTH-1];

    reg [ROW_BITS-1:0] open_row [0:SIM_BANKS-1];
    reg                row_open [0:SIM_BANKS-1];

    reg [15:0] dq_out;
    reg        dq_oe;

    assign dq = dq_oe ? dq_out : 16'hZZZZ;

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

    reg        rd_pending;
    integer    rd_cnt;
    integer    rd_bank, rd_row, rd_col;

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
        if (cs_n || !cke) begin
            dq_oe      <= 1'b0;
            rd_pending <= 1'b0;
            rd_cnt     <= 0;
        end else begin
            case (cmd)
                CMD_ACTIVE: begin
                    if (ba < SIM_BANKS) begin
                        open_row[ba] <= addr[ROW_BITS-1:0];
                        row_open[ba] <= 1'b1;
                    end
                    dq_oe <= 1'b0;
                end

                CMD_READ: begin
                    if (ba < SIM_BANKS && row_open[ba]) begin
                        bank_i = ba;
                        row_i  = open_row[ba];
                        col_i  = addr[COL_BITS-1:0];

                        row_i = row_i % SIM_ROWS;
                        col_i = col_i % SIM_COLS;

                        rd_bank    <= bank_i;
                        rd_row     <= row_i;
                        rd_col     <= col_i;
                        rd_cnt     <= CL_CYCLES;
                        rd_pending <= 1'b1;
                        dq_oe      <= 1'b0;

                        if (addr[10]) begin
                            row_open[ba] <= 1'b0;
                        end
                    end else begin
                        rd_pending <= 1'b0;
                        rd_cnt     <= 0;
                        dq_oe      <= 1'b0;
                    end
                end

                CMD_WRITE: begin
                    dq_oe <= 1'b0;

                    if (ba < SIM_BANKS && row_open[ba]) begin
                        bank_i = ba;
                        row_i  = open_row[ba];
                        col_i  = addr[COL_BITS-1:0];

                        row_i = row_i % SIM_ROWS;
                        col_i = col_i % SIM_COLS;

                        idx       = linear_addr(bank_i, row_i, col_i);
                        mem[idx] <= dq;

                        if (addr[10]) begin
                            row_open[ba] <= 1'b0;
                        end
                    end
                end

                CMD_PRECH: begin
                    if (addr[10]) begin
                        for (i = 0; i < SIM_BANKS; i = i + 1)
                            row_open[i] <= 1'b0;
                    end else begin
                        if (ba < SIM_BANKS)
                            row_open[ba] <= 1'b0;
                    end
                    dq_oe <= 1'b0;
                end

                CMD_REF: begin
                    dq_oe <= 1'b0;
                end

                CMD_MRS: begin
                    dq_oe <= 1'b0;
                end

                default: begin
                end
            endcase

            if (rd_pending) begin
                if (rd_cnt > 0) begin
                    rd_cnt <= rd_cnt - 1;
                    if (rd_cnt == 1) begin
                        row_i = rd_row % SIM_ROWS;
                        col_i = rd_col % SIM_COLS;
                        idx   = linear_addr(rd_bank, row_i, col_i);

                        dq_out <= mem[idx];
                        dq_oe  <= 1'b1;
                    end
                end
            end
        end
    end

endmodule

`default_nettype wire