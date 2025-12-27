`timescale 1ns/1ps
`default_nettype none

module sdram_timer (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        load,
    input  wire [15:0] value,
    output wire        done
);
    reg [15:0] timer;
    assign done = (timer == 16'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            timer <= 16'd0;
        end else begin
            if (load) timer <= value;
            else if (timer != 16'd0) timer <= timer - 16'd1;
        end
    end
endmodule

`default_nettype wire
