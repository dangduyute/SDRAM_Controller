`timescale 1ns/1ps
`default_nettype none

module tb_sdram_ctrl ();

    parameter ROW_BITS  = 13;
    parameter COL_BITS  = 9;
    parameter BANK_BITS = 2;
    parameter CLK_PERIOD = 10;

    localparam [4:0] S_IDLE_TB = 5'd10;

    reg clk;
    reg rst_n;

    reg                   cmd_valid;
    reg                   cmd_write;
    reg [ROW_BITS+COL_BITS+BANK_BITS-1:0] cmd_addr;
    reg [15:0]            cmd_wdata;
    wire                  cmd_ready;

    wire                  rsp_valid;
    wire [15:0]           rsp_rdata;
    reg                   rsp_ready;

    wire                  sd_clk;
    wire                  sd_cke;
    wire                  sd_cs_n;
    wire                  sd_ras_n;
    wire                  sd_cas_n;
    wire                  sd_we_n;
    wire [BANK_BITS-1:0]  sd_ba;
    wire [12:0]           sd_addr;
    wire [15:0]           sd_dq;
    wire [1:0]            sd_dqm;

    wire                  error_flag;
    wire [4:0]            state_out;

    integer test_count = 0;
    integer pass_count = 0;
    integer fail_count = 0;

    time    read_cmd_bus_time;
    reg     measure_read_timing;

    sdram_ctrl #(
        .ROW_BITS    (ROW_BITS),
        .COL_BITS    (COL_BITS),
        .BANK_BITS   (BANK_BITS),
        .T_INIT_100US(1000),
        .T_RP        (3),
        .T_RCD       (3),
        .T_RFC       (7),
        .T_MRD       (2),
        .T_WR        (3),
        .T_REF_INT   (32'h7FFFFFFF),
        .CL          (3)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .cmd_valid  (cmd_valid),
        .cmd_write  (cmd_write),
        .cmd_addr   (cmd_addr),
        .cmd_wdata  (cmd_wdata),
        .rsp_ready  (rsp_ready),
        .cmd_ready  (cmd_ready),
        .rsp_valid  (rsp_valid),
        .rsp_rdata  (rsp_rdata),
        .sd_clk     (sd_clk),
        .sd_cke     (sd_cke),
        .sd_cs_n    (sd_cs_n),
        .sd_ras_n   (sd_ras_n),
        .sd_cas_n   (sd_cas_n),
        .sd_we_n    (sd_we_n),
        .sd_ba      (sd_ba),
        .sd_addr    (sd_addr),
        .sd_dq      (sd_dq),
        .sd_dqm     (sd_dqm),
        .error_flag (error_flag),
        .state_out  (state_out)
    );

    sdram_model #(
        .ROW_BITS (ROW_BITS),
        .COL_BITS (COL_BITS),
        .BANK_BITS(BANK_BITS),
        .CL_CYCLES  (3)
    ) sdram (
        .clk   (sd_clk),
        .cke   (sd_cke),
        .cs_n  (sd_cs_n),
        .ras_n (sd_ras_n),
        .cas_n (sd_cas_n),
        .we_n  (sd_we_n),
        .ba    (sd_ba),
        .addr  (sd_addr),
        .dq    (sd_dq),
        .dqm   (sd_dqm)
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    initial begin
        rst_n = 1'b0;
        measure_read_timing = 1'b0;
        #(10*CLK_PERIOD);
        rst_n = 1'b1;
    end

    initial begin
        cmd_valid = 1'b0;
        cmd_write = 1'b0;
        cmd_addr  = { (ROW_BITS+COL_BITS+BANK_BITS){1'b0} };
        cmd_wdata = 16'd0;
        rsp_ready = 1'b1;

        wait(state_out == S_IDLE_TB);
        #(100);
        
        $display("\n__________________________________________");
        $display("|  SDRAM Controller Test Suite Started  |");
        $display("|  Initialization complete              |");
        $display("__________________________________________\n");

        test_write_read_single();
        #(100);
        test_multiple_writes();
        #(100);
        test_multiple_reads();
        #(100);
        test_different_banks();
        #(100);
        test_cas_latency_timing();
        #(100);
        test_back_to_back();
        #(100);
        test_response_hold();

        #(1000);
        print_test_summary();
        $finish;
    end

    task test_write_read_single();
        reg [15:0] write_val, read_val;
        reg [23:0] test_addr;
        begin
            $display("\n[TEST 1] Single WRITE & READ");
            $display("------------------------------------------");
            
            test_addr = 24'h123456;
            write_val = 16'hABCD;
            
            write_operation(write_val, test_addr);
            #(50);
            read_operation(test_addr, read_val);
            
            if (read_val == write_val) begin
                $display("PASS: Data matched! (0x%04x == 0x%04x)", read_val, write_val);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL: Data mismatch! (Read: 0x%04x, Expected: 0x%04x)", read_val, write_val);
                fail_count = fail_count + 1;
            end
            test_count = test_count + 1;
        end
    endtask

    task test_multiple_writes();
        integer i;
        reg [15:0] data;
        reg [23:0] addr;
        begin
            $display("\n[TEST 2] Multiple Sequential Writes");
            $display("------------------------------------------");

            for (i = 0; i < 4; i = i + 1) begin
                addr = 24'h200000 + i;
                data = 16'h1000 + i;
                write_operation(data, addr);
                $display("  Write[%0d]: addr=0x%06x, data=0x%04x", i, addr, data);
            end

            $display("PASS: All 4 writes completed");
            pass_count = pass_count + 1;
            test_count = test_count + 1;
        end
    endtask

    task test_multiple_reads();
        integer i;
        reg [15:0] read_val;
        reg [23:0] addr;
        begin
            $display("\n[TEST 3] Multiple Sequential Reads");
            $display("------------------------------------------");

            for (i = 0; i < 4; i = i + 1) begin
                addr = 24'h200000 + i;
                read_operation(addr, read_val);
                $display("  Read[%0d]: addr=0x%06x, data=0x%04x", i, addr, read_val);
            end

            $display("PASS: All 4 reads completed");
            pass_count = pass_count + 1;
            test_count = test_count + 1;
        end
    endtask

    task test_different_banks();
        integer b;
        reg [15:0] data, read_val;
        reg [23:0] addr;
        begin
            $display("\n[TEST 4] Different Bank Access");
            $display("------------------------------------------");

            for (b = 0; b < 4; b = b + 1) begin
                addr = 24'hABCD00 | b;
                data = 16'h4000 + (b << 8);
                
                write_operation(data, addr);
                $display("  Bank %0d: Write 0x%04x to 0x%06x", b, data, addr);
            end

            for (b = 0; b < 4; b = b + 1) begin
                addr = 24'hABCD00 | b;
                read_operation(addr, read_val);
                $display("  Bank %0d: Read back 0x%04x (expected 0x%04x) at 0x%06x",
                          b, read_val, 16'h4000 + (b << 8), addr);
            end

            $display("PASS: All banks accessed and verified");
            pass_count = pass_count + 1;
            test_count = test_count + 1;
        end
    endtask

    task test_cas_latency_timing();
        reg [15:0] data, read_val;
        reg [23:0] addr;
        time data_valid_time;
        time expected_delay;
        time delay_measured;
        integer timeout_cnt;
        begin
            $display("\n[TEST 5] CAS Latency Timing Verification");
            $display("------------------------------------------");

            addr = 24'h300000;
            data = 16'hCAFE;

            write_operation(data, addr);
            #(100);
            measure_read_timing = 1'b1;
            wait(state_out == S_IDLE_TB);
            @(posedge clk);
            
            cmd_valid = 1'b1;
            cmd_write = 1'b0;
            cmd_addr  = addr;
            $display("  [TB] READ request sent at host time %0t", $time);

            wait(cmd_ready);
            @(posedge clk);
            cmd_valid = 1'b0;

            timeout_cnt = 0;
            while (!rsp_valid && timeout_cnt < 500) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
            end

            measure_read_timing = 1'b0;

            if (!rsp_valid) begin
                $display("FAIL: rsp_valid timeout after %0d clocks", timeout_cnt);
                fail_count = fail_count + 1;
            end else begin
                @(posedge clk);
                data_valid_time = $time;
                read_val        = rsp_rdata;
                
                delay_measured = data_valid_time - read_cmd_bus_time;
                expected_delay = (3 * CLK_PERIOD);
                
                $display("  [BUS] READ command on SDRAM at %0t", read_cmd_bus_time);
                $display("  [BUS] Data valid on rsp_valid at %0t", data_valid_time);
                $display("  Delay: %0t ns (Expected around %0t ns)", delay_measured, expected_delay);

                if (read_val == data) begin
                    $display("PASS: CAS latency check & data valid (0x%04x)", read_val);
                    pass_count = pass_count + 1;
                end else begin
                    $display("FAIL: Data mismatch (Got 0x%04x, Expected 0x%04x)", 
                             read_val, data);
                    fail_count = fail_count + 1;
                end
            end
            test_count = test_count + 1;
        end
    endtask

    task test_back_to_back();
        reg [15:0] write_val1, write_val2, read_val1, read_val2;
        reg [23:0] addr1, addr2;
        begin
            $display("\n[TEST 6] Back-to-Back Write/Read");
            $display("------------------------------------------");

            addr1 = 24'h400000;
            addr2 = 24'h400001;
            write_val1 = 16'hFEDC;
            write_val2 = 16'hBA98;

            write_operation(write_val1, addr1);
            write_operation(write_val2, addr2);
            $display("  Write1: addr=0x%06x, data=0x%04x", addr1, write_val1);
            $display("  Write2: addr=0x%06x, data=0x%04x", addr2, write_val2);

            read_operation(addr1, read_val1);
            read_operation(addr2, read_val2);

            if ((read_val1 == write_val1) && (read_val2 == write_val2)) begin
                $display("  PASS: Back-to-back ops OK");
                $display("  Addr1: 0x%04x == 0x%04x", read_val1, write_val1);
                $display("  Addr2: 0x%04x == 0x%04x", read_val2, write_val2);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL: Data mismatch in back-to-back");
                fail_count = fail_count + 1;
            end
            test_count = test_count + 1;
        end
    endtask

    task test_response_hold();
        reg [15:0] write_val, read_val1, read_val2;
        reg [23:0] addr;
        integer timeout_cnt;
        begin
            $display("\n[TEST 7] Response Hold (Backpressure) Verification");
            $display("------------------------------------------");

            addr      = 24'h500000;
            write_val = 16'hDEAD;

            write_operation(write_val, addr);
            #(100);

            wait(state_out == S_IDLE_TB);
            @(posedge clk);

            rsp_ready = 1'b0;

            cmd_valid = 1'b1;
            cmd_write = 1'b0;
            cmd_addr  = addr;

            wait(cmd_ready);
            @(posedge clk);
            cmd_valid = 1'b0;
            cmd_write = 1'b0;
            cmd_addr  = 24'd0;

            timeout_cnt = 0;
            while (!rsp_valid && timeout_cnt < 1000) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
            end

            if (!rsp_valid) begin
                $display("FAIL: rsp_valid timeout in TEST 7");
                fail_count = fail_count + 1;
            end else begin
                read_val1 = rsp_rdata;
                $display("  Sample#1 (rsp_ready=0): 0x%04x", read_val1);

                repeat (3) begin
                    @(posedge clk);
                    if (!rsp_valid) begin
                        $display("FAIL: rsp_valid was not held under backpressure!");
                        fail_count = fail_count + 1;
                        disable test_response_hold;
                    end
                end

                read_val2 = rsp_rdata;
                $display("  Sample#2 after hold     : 0x%04x", read_val2);

                rsp_ready = 1'b1;
                @(posedge clk);

                if (read_val1 == write_val && read_val2 == write_val) begin
                    $display("PASS: rsp_valid & rsp_rdata held correctly. Data=0x%04x", write_val);
                    pass_count = pass_count + 1;
                end else begin
                    $display("FAIL: Data incorrect (sample1=0x%04x sample2=0x%04x expected=0x%04x)",
                             read_val1, read_val2, write_val);
                    fail_count = fail_count + 1;
                end
            end

            rsp_ready = 1'b1;
            test_count = test_count + 1;
        end
    endtask

    task write_operation(
        input [15:0] wdata,
        input [23:0] addr
    );
        begin
            wait(state_out == S_IDLE_TB);
            @(posedge clk);
            
            cmd_valid = 1'b1;
            cmd_write = 1'b1;
            cmd_addr  = addr;
            cmd_wdata = wdata;

            wait(cmd_ready);
            @(posedge clk);
            cmd_valid = 1'b0;
            cmd_write = 1'b0;
            cmd_addr  = 24'd0;
            cmd_wdata = 16'd0;

            wait(state_out == S_IDLE_TB);
        end
    endtask

    task read_operation(
        input  [23:0] addr,
        output [15:0] rdata
    );
        integer timeout_cnt;
        begin
            wait(state_out == S_IDLE_TB);
            @(posedge clk);
            
            cmd_valid = 1'b1;
            cmd_write = 1'b0;
            cmd_addr  = addr;

            wait(cmd_ready);
            @(posedge clk);
            cmd_valid = 1'b0;
            cmd_write = 1'b0;
            cmd_addr  = 24'd0;

            timeout_cnt = 0;
            while (!rsp_valid && timeout_cnt < 1000) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
            end

            if (!rsp_valid) begin
                $display("ERROR: rsp_valid timeout! state=%0d, timeout_cnt=%0d", state_out, timeout_cnt);
                rdata = 16'h0000;
            end else begin
                @(posedge clk);
                rdata = rsp_rdata;
            end
        end
    endtask

    task print_test_summary();
        begin
            $display("\n_________________________________________");
            $display("|         Test Summary Report           |");
            $display("_________________________________________");
            $display("|  Total Tests: %2d                      |", test_count);
            $display("|  Passed:      %2d                      |", pass_count);
            $display("|  Failed:      %2d                      |", fail_count);
            if (fail_count == 0)
                $display("|  Result: ALL TESTS PASSED!            |");
            else
                $display("|  Result: SOME TESTS FAILED!           |");
            $display("_________________________________________\n");
        end
    endtask


    always @(posedge clk) begin
        if (sd_cs_n == 1'b0) begin
            case ({sd_ras_n, sd_cas_n, sd_we_n})
                3'b011: $display("[%0t] SDRAM_CMD: ACTIVE   | Bank=%0d, Row=0x%03x",
                                  $time, sd_ba, sd_addr[12:0]);
                3'b101: begin
                    if (measure_read_timing) begin
                        read_cmd_bus_time = $time;
                    end
                    $display("[%0t] SDRAM_CMD: READ     | Bank=%0d, Col=0x%03x, AP=%b",
                              $time, sd_ba, sd_addr[8:0], sd_addr[10]);
                end
                3'b100: $display("[%0t] SDRAM_CMD: WRITE    | Bank=%0d, Col=0x%03x, AP=%b, Data=0x%04x",
                                  $time, sd_ba, sd_addr[8:0], sd_addr[10], sd_dq);
                3'b010: $display("[%0t] SDRAM_CMD: PRECHARGE| %s",
                                  $time, sd_addr[10] ? "All Banks" : "Single Bank");
                3'b001: $display("[%0t] SDRAM_CMD: REFRESH", $time);
                3'b000: $display("[%0t] SDRAM_CMD: MODE REG SET | MR=0x%03x",
                                  $time, sd_addr[11:0]);
            endcase
        end
    end

    always @(posedge clk) begin
        if (rsp_valid) begin
            $display("[%0t] RESPONSE: rsp_valid=1, rsp_rdata=0x%04x", $time, rsp_rdata);
        end
    end

    initial begin
        #500000;
        $display("\n??  TIMEOUT: Simulation took too long!");
        $finish;
    end

endmodule

`default_nettype wire