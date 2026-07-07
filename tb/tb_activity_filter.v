`timescale 1ns/1ps
`default_nettype none

// Unit bench for activity_filter (background-activity filter).
//
// Two DUTs share the same stimulus pins:
//   dut_off (EN=0) — must be fully transparent
//   dut_on  (EN=1) — must enforce spatial-support filtering
//
// Tile geometry: XW=YW=10, AW=8 -> HX=HY=4, 16x16 tiles of 64x64 px.
// WINDOW=200 cycles keeps expiry tests short.

module tb_activity_filter;

    localparam XW = 10;
    localparam YW = 10;
    localparam AW = 8;
    localparam WINDOW = 200;
    localparam TILE = 64;   // px per tile (2^(XW-HX))

    reg clk = 0;
    always #5 clk = ~clk;

    reg rst = 1;
    reg           in_valid = 0;
    reg  [XW-1:0] in_x = 0;
    reg  [YW-1:0] in_y = 0;
    reg           in_pol = 0;

    wire          off_valid, off_pol;
    wire [XW-1:0] off_x;
    wire [YW-1:0] off_y;
    wire          off_drop;

    wire          on_valid, on_pol;
    wire [XW-1:0] on_x;
    wire [YW-1:0] on_y;
    wire          on_drop;

    activity_filter #(.XW(XW), .YW(YW), .AW(AW), .WINDOW(WINDOW), .EN(0)) dut_off (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_x(in_x), .in_y(in_y), .in_pol(in_pol),
        .out_valid(off_valid), .out_x(off_x), .out_y(off_y), .out_pol(off_pol),
        .dropped(off_drop)
    );

    activity_filter #(.XW(XW), .YW(YW), .AW(AW), .WINDOW(WINDOW), .EN(1)) dut_on (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_x(in_x), .in_y(in_y), .in_pol(in_pol),
        .out_valid(on_valid), .out_x(on_x), .out_y(on_y), .out_pol(on_pol),
        .dropped(on_drop)
    );

    integer errors = 0;
    integer tests  = 0;

    // Drive one event and check the EN=1 filter's pass/drop decision.
    // The decision is combinational, so it is sampled while in_valid is high;
    // the event is then held across one posedge so the timestamp write lands.
    task send_ev;
        input [XW-1:0] ex;
        input [YW-1:0] ey;
        input          pol;
        input          expect_pass;
        begin
            @(negedge clk);
            in_x = ex; in_y = ey; in_pol = pol; in_valid = 1'b1;
            #1;
            tests = tests + 1;
            if (on_valid !== expect_pass) begin
                errors = errors + 1;
                $display("FAIL: event (%0d,%0d) expected %s but filter said %s",
                         ex, ey, expect_pass ? "PASS" : "DROP",
                         on_valid ? "PASS" : "DROP");
            end
            if (!off_valid) begin
                errors = errors + 1;
                $display("FAIL: EN=0 instance not transparent for (%0d,%0d)", ex, ey);
            end
            if (off_x !== ex || off_y !== ey || off_pol !== pol
                || on_x !== ex || on_y !== ey || on_pol !== pol) begin
                errors = errors + 1;
                $display("FAIL: coordinate/polarity pass-through corrupted for (%0d,%0d)", ex, ey);
            end
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    task idle;
        input integer n;
        begin
            repeat (n) @(posedge clk);
        end
    endtask

    initial begin
        // Reset long enough for the sequential table clear (2^AW cycles)
        repeat (300) @(posedge clk);
        rst = 0;
        idle(5);

        // T1: first event in a silent region -> dropped (no support)
        $display("TEST 1: isolated first event dropped");
        send_ev(2*TILE + 10, 2*TILE + 10, 1'b1, 1'b0);

        // T2: second event, same tile, within window -> self-support -> pass
        $display("TEST 2: same-tile self-support passes");
        idle(10);
        send_ev(2*TILE + 20, 2*TILE + 20, 1'b0, 1'b1);

        // T3: cardinal neighbour support -> pass
        $display("TEST 3: cardinal neighbour support passes");
        idle(10);
        send_ev(3*TILE + 5, 2*TILE + 5, 1'b1, 1'b1);   // tile (3,2), neighbour of (2,2)

        // T4: diagonal neighbour support -> pass
        $display("TEST 4: diagonal neighbour support passes");
        idle(10);
        send_ev(4*TILE + 5, 3*TILE + 5, 1'b1, 1'b1);   // tile (4,3), diagonal of (3,2)

        // T5: outside the window -> dropped
        $display("TEST 5: expired support dropped");
        idle(WINDOW + 300);                            // > WINDOW + full scrub sweep
        send_ev(5*TILE + 5, 3*TILE + 5, 1'b1, 1'b0);   // neighbour of (4,3) but stale

        // T6: far tile, no wraparound support from earlier corner activity
        $display("TEST 6: no boundary wraparound");
        send_ev(10'd5, 10'd5, 1'b1, 1'b0);             // tile (0,0), silent region
        idle(10);
        send_ev(10'd1000, 10'd1000, 1'b1, 1'b0);       // tile (15,15): (0,0) must not support it

        // T7: dropped events still deposit support for the next one
        $display("TEST 7: dropped event deposits support");
        idle(10);
        send_ev(10'd1010, 10'd1010, 1'b1, 1'b1);       // tile (15,15) again, now self-supported

        // Summary
        $display("");
        $display("=== TEST SUMMARY ===");
        $display("Tests run: %0d", tests);
        $display("Errors: %0d", errors);
        if (errors == 0) begin
            $display("All ACTIVITY_FILTER tests passed!");
            $display("PASS");
        end else begin
            $display("FAIL: %0d error(s)", errors);
        end
        $finish;
    end

    initial begin
        #2_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
