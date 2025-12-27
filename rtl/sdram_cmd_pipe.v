`timescale 1ns/1ps
`default_nettype none

module sdram_cmd_pipe #(
    parameter ROW_BITS  = 13,
    parameter COL_BITS  = 9,
    parameter BANK_BITS = 2
)(
    input  wire                                    clk,
    input  wire                                    rst_n,

    input  wire                                    cmd_valid,
    input  wire                                    cmd_write,
    input  wire [ROW_BITS+COL_BITS+BANK_BITS-1:0]  cmd_addr,
    input  wire [15:0]                             cmd_wdata,

    // pulse from FSM when a command is accepted in IDLE
    input  wire                                    accept_q_pulse,

    output reg                                     cmd_valid_r,
    output reg                                     cmd_write_r,
    output reg [ROW_BITS+COL_BITS+BANK_BITS-1:0]    cmd_addr_r,
    output reg [15:0]                              cmd_wdata_r,

    output reg                                     cmd_write_q,
    output reg [ROW_BITS+COL_BITS+BANK_BITS-1:0]    cmd_addr_q,
    output reg [15:0]                              cmd_wdata_q
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmd_valid_r <= 1'b0;
            cmd_write_r <= 1'b0;
            cmd_addr_r  <= {(ROW_BITS+COL_BITS+BANK_BITS){1'b0}};
            cmd_wdata_r <= 16'd0;

            cmd_write_q <= 1'b0;
            cmd_addr_q  <= {(ROW_BITS+COL_BITS+BANK_BITS){1'b0}};
            cmd_wdata_q <= 16'd0;
        end else begin
            // stage R: sample inputs to avoid TB race
            cmd_valid_r <= cmd_valid;
            cmd_write_r <= cmd_write;
            cmd_addr_r  <= cmd_addr;
            cmd_wdata_r <= cmd_wdata;

            // stage Q: latch accepted command from stage R (stable)
            if (accept_q_pulse) begin
                cmd_write_q <= cmd_write_r;
                cmd_addr_q  <= cmd_addr_r;
                cmd_wdata_q <= cmd_wdata_r;
            end
        end
    end
endmodule

`default_nettype wire
