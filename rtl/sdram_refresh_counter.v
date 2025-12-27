`timescale 1ns/1ps
`default_nettype none

module sdram_refresh_counter #(
    parameter integer T_REF_INT = 7800
)(
    input  wire clk,
    input  wire rst_n,
    input  wire in_init,
    input  wire refresh_clear_pulse,
    output reg  refresh_pending
);
    reg [31:0] ref_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ref_cnt         <= 32'd0;
            refresh_pending <= 1'b0;
        end else begin
            if (in_init) begin
                ref_cnt         <= 32'd0;
                refresh_pending <= 1'b0;
            end else begin
                if (refresh_clear_pulse) begin
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
endmodule

`default_nettype wire
