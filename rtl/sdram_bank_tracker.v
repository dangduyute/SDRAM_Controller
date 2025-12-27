`timescale 1ns/1ps
`default_nettype none

module sdram_bank_tracker #(
    parameter ROW_BITS  = 13,
    parameter BANK_BITS = 2
)(
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire                 set_active_pulse,
    input  wire [BANK_BITS-1:0] set_bank,
    input  wire [ROW_BITS-1:0]  set_row,

    input  wire                 clear_active_pulse,
    input  wire [BANK_BITS-1:0] clear_bank,

    input  wire [BANK_BITS-1:0] query_bank,
    input  wire [ROW_BITS-1:0]  query_row,
    output wire                 row_hit
);
    localparam NUM_BANKS = (1 << BANK_BITS);

    reg [ROW_BITS-1:0]  active_row [0:NUM_BANKS-1];
    reg [NUM_BANKS-1:0] bank_active;
    integer i;

    assign row_hit = bank_active[query_bank] && (active_row[query_bank] == query_row);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bank_active <= {NUM_BANKS{1'b0}};
            for (i = 0; i < NUM_BANKS; i = i + 1)
                active_row[i] <= {ROW_BITS{1'b0}};
        end else begin
            if (set_active_pulse) begin
                bank_active[set_bank] <= 1'b1;
                active_row[set_bank]  <= set_row;
            end
            if (clear_active_pulse) begin
                bank_active[clear_bank] <= 1'b0;
            end
        end
    end
endmodule

`default_nettype wire
