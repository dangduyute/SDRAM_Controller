`timescale 1ns/1ps
`default_nettype none

module sdram_rsp_capture (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        capture_pulse,
    input  wire [15:0] dq_in,
    input  wire        rsp_ready,
    output reg         rsp_valid,
    output reg [15:0]  rsp_rdata
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rsp_valid <= 1'b0;
            rsp_rdata <= 16'd0;
        end else begin
            if (capture_pulse) begin
                rsp_rdata <= dq_in;
                rsp_valid <= 1'b1;
            end else if (rsp_valid && !rsp_ready) begin
                rsp_valid <= 1'b1; // hold under backpressure
            end else begin
                rsp_valid <= 1'b0;
            end
        end
    end
endmodule

`default_nettype wire
