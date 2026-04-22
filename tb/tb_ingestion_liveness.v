`timescale 1ns/1ps
`default_nettype none

// Gate 2 ingestion bench: exercises different scheduling contracts and observes
// LIBELLULA_DIAG counters. Requires -DLIBELLULA_DIAG at compile time.
//
// Adapted from CDX tb_ingestion_liveness for v22:
//   - hash() uses spatial tile hash: {x[XW-1:XW-HX], y[YW-1:YW-HY]}
//     (was XOR hash in CDX; must match lif_tile_tmux's hashed_xy)
//   - LEAK_SHIFT left at default (4) — v22 lif_tile_tmux default
//   - out_ex/out_ey ports connected (open)
module tb_ingestion_liveness;
    localparam T_NS = 5;
    localparam XW = 8;
    localparam YW = 8;
    localparam AW = 4;
    localparam SW = 14;
    localparam integer HX = AW / 2;   // bits from x for spatial hash
    localparam integer HY = AW - HX;  // bits from y for spatial hash
    localparam integer NUM_EVENTS = 6;

    reg clk = 0;
    always #(T_NS/2) clk = ~clk;

    reg rst = 1'b1;
    reg in_valid = 1'b0;
    reg [XW-1:0] in_x = {XW{1'b0}};
    reg [YW-1:0] in_y = {YW{1'b0}};
    reg in_pol = 1'b0;
    reg [AW-1:0] scan_addr = {AW{1'b0}};
    reg force_scan = 1'b0;
    reg [AW-1:0] forced_scan_addr = {AW{1'b0}};

    wire out_valid;
    wire [XW-1:0] out_x;
    wire [YW-1:0] out_y;
    wire out_pol;

    lif_tile_tmux #(
        .XW(XW), .YW(YW), .AW(AW), .SW(SW),
        .THRESH(16)
    ) dut (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_x(in_x), .in_y(in_y), .in_pol(in_pol),
        .scan_addr(scan_addr),
        .out_valid(out_valid), .out_x(out_x), .out_y(out_y), .out_pol(out_pol),
        .out_ex(), .out_ey()
    );

    reg [XW-1:0] ev_x [0:NUM_EVENTS-1];
    reg [YW-1:0] ev_y [0:NUM_EVENTS-1];
    integer idx;
    initial begin
        for (idx = 0; idx < NUM_EVENTS; idx = idx + 1) begin
            ev_x[idx] = 8'(idx + 3);
            ev_y[idx] = 8'(idx + 7);
        end
    end

    // Spatial tile hash: must match lif_tile_tmux's hashed_xy exactly.
    function automatic [AW-1:0] hash(input [XW-1:0] x, input [YW-1:0] y);
        hash = {x[XW-1:XW-HX], y[YW-1:YW-HY]};
    endfunction

    // Auto scanner increments scan_addr unless override requested
    always @(posedge clk) begin
        if (rst)
            scan_addr <= {AW{1'b0}};
        else if (force_scan)
            scan_addr <= forced_scan_addr;
        else
            scan_addr <= scan_addr + {{(AW-1){1'b0}}, 1'b1};
    end

    task automatic pulse_event(input [XW-1:0] x, input [YW-1:0] y);
        begin
            @(negedge clk);
            in_valid = 1'b1;
            in_x = x;
            in_y = y;
            in_pol = 1'b1;
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    task automatic wait_for_scan(input [AW-1:0] addr);
        integer guard;
        begin
            guard = 0;
            while (scan_addr !== addr) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 2000) begin
                    $display("ERROR: wait_for_scan timeout at addr %0d", addr);
                    disable wait_for_scan;
                end
            end
        end
    endtask

    task automatic run_unscheduled;
        begin
            force_scan = 0;
            for (idx = 0; idx < NUM_EVENTS; idx = idx + 1) begin
                pulse_event(ev_x[idx], ev_y[idx]);
                @(negedge clk);
            end
        end
    endtask

    task automatic run_wait;
        begin
            force_scan = 0;
            for (idx = 0; idx < NUM_EVENTS; idx = idx + 1) begin
                wait_for_scan(hash(ev_x[idx], ev_y[idx]));
                force_scan = 1;
                forced_scan_addr = hash(ev_x[idx], ev_y[idx]);
                pulse_event(ev_x[idx], ev_y[idx]);
                @(negedge clk);
                force_scan = 0;
                @(negedge clk);
            end
        end
    endtask

    task automatic run_hold;
        begin
            for (idx = 0; idx < NUM_EVENTS; idx = idx + 1) begin
                force_scan = 1;
                forced_scan_addr = hash(ev_x[idx], ev_y[idx]);
                @(negedge clk);
                pulse_event(ev_x[idx], ev_y[idx]);
                @(negedge clk);
            end
            force_scan = 0;
        end
    endtask

    task automatic run_retry;
        integer goal_accepts;
        begin
            force_scan = 0;
            for (idx = 0; idx < NUM_EVENTS; idx = idx + 1) begin
                in_x = ev_x[idx];
                in_y = ev_y[idx];
                in_pol = 1'b1;
                goal_accepts = dut.events_accepted + 1;
                in_valid = 1'b1;
                while (dut.events_accepted < goal_accepts) begin
                    @(negedge clk);
                end
                in_valid = 1'b0;
                @(negedge clk);
            end
        end
    endtask

    always @(posedge clk) begin
        if (!rst && in_valid) begin
            $display("DEBUG: scan=%0d hash=%0d in_valid=%0b", scan_addr, hash(in_x, in_y), in_valid);
        end
    end

    string mode;
    integer errors = 0;

    initial begin
        if (!$value$plusargs("MODE=%s", mode))
            mode = "unscheduled";

        $display("=== tb_ingestion_liveness MODE=%s ===", mode);

        repeat (4) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);

        if (mode == "unscheduled")
            run_unscheduled();
        else if (mode == "wait")
            run_wait();
        else if (mode == "hold")
            run_hold();
        else if (mode == "retry")
            run_retry();
        else begin
            $display("ERROR: Unknown MODE=%s", mode);
            errors = errors + 1;
        end

        repeat (10) @(negedge clk);

        $display("Counters: presented=%0d accepted=%0d retimed=%0d spikes=%0d updates=%0d",
                 dut.events_presented, dut.events_accepted,
                 dut.events_retimed, dut.lif_spikes, dut.lif_updates);
        $display("INGEST_SUMMARY,%s,%0d,%0d,%0d,%0d,%0d",
                 mode,
                 dut.events_presented,
                 dut.events_accepted,
                 dut.events_retimed,
                 dut.lif_updates,
                 dut.lif_spikes);

        if (dut.events_presented != NUM_EVENTS || dut.events_accepted != NUM_EVENTS) begin
            $display("ERROR: expected every event to be accepted");
            errors = errors + 1;
        end

        if (mode == "unscheduled") begin
            if (dut.events_retimed == 0) begin
                $display("ERROR: unscheduled mode should require retiming");
                errors = errors + 1;
            end
        end else if (mode == "wait" || mode == "hold") begin
            if (dut.events_retimed != 0) begin
                $display("ERROR: wait/hold mode should have zero retimed events");
                errors = errors + 1;
            end
        end else if (mode == "retry") begin
            if (dut.events_retimed == 0) begin
                $display("ERROR: retry mode should record at least one retimed event");
                errors = errors + 1;
            end
        end

        $finish(errors == 0 ? 0 : 1);
    end
endmodule

`default_nettype wire
