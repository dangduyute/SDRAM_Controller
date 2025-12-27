`timescale 1ns/1ps
`default_nettype none

module sdram_watchdog #(
    parameter integer IDLE_THRESH = 100000
)(
    input  wire clk,
    input  wire rst_n,
    input  wire in_idle,
    input  wire cmd_valid_raw,
    input  wire in_error_state,
    output reg  error_flag
);
    reg [15:0] idle_timeout;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idle_timeout <= 16'd0;
            error_flag   <= 1'b0;
        end else begin
            if (in_idle && !cmd_valid_raw) begin
                if (idle_timeout != 16'hFFFF)
                    idle_timeout <= idle_timeout + 16'd1;
            end else begin
                idle_timeout <= 16'd0;
            end

            if ((idle_timeout > IDLE_THRESH[15:0]) || in_error_state)
                error_flag <= 1'b1;
        end
    end
endmodule

`default_nettype wire
