`timescale 1ns/1ps
`default_nettype none

// 8-direction retinotopic delay lattice using a ring buffer.
// Provides event-based delay for Reichardt correlation detection.
//
// DELAY SEMANTICS (event-based):
// - Events are delayed by DEPTH events, not DEPTH cycles
// - The ring buffer holds DEPTH = 2^DW entries
// - On each in_valid, we read the oldest entry (DEPTH events ago), then overwrite it
// - This creates a sliding window of the most recent DEPTH events
//
// SPATIAL CORRELATION (8-connected neighborhood):
// Cardinal directions:
// - East:  delayed event was from (x+1, y),   current at (x, y) -> rightward motion
// - West:  delayed event was from (x-1, y),   current at (x, y) -> leftward motion
// - North: delayed event was from (x, y+1),   current at (x, y) -> upward motion
// - South: delayed event was from (x, y-1),   current at (x, y) -> downward motion
// Diagonal directions:
// - NE: delayed event was from (x+1, y+1), current at (x, y) -> NE motion
// - NW: delayed event was from (x-1, y+1), current at (x, y) -> NW motion
// - SE: delayed event was from (x+1, y-1), current at (x, y) -> SE motion
// - SW: delayed event was from (x-1, y-1), current at (x, y) -> SW motion
//
// BOUNDARY HANDLING:
// - Neighbor comparisons use explicit boundary checks to avoid wraparound false positives
// - Events at image edges will not produce spurious correlations
//
// DW=0 (DEPTH=1): Pass-through mode with 1-event delay (compare current with previous)
module delay_lattice_rb #(
    parameter XW=10, YW=10, DW=6,  // delay depth bits: depth = 2^DW events
    parameter STEP=1                // neighbor step size in coordinate units (set to tile size when using tile hash)
)(
    input  wire          clk, rst,
    input  wire          in_valid,
    input  wire [XW-1:0] in_x,
    input  wire [YW-1:0] in_y,
    input  wire          in_pol,
    // Cardinal correlation outputs (4-connected)
    output reg           v_e = 1'b0,      // correlation from East neighbor (rightward motion)
    output reg           v_w = 1'b0,      // correlation from West neighbor (leftward motion)
    output reg           v_n = 1'b0,      // correlation from North neighbor (upward motion)
    output reg           v_s = 1'b0,      // correlation from South neighbor (downward motion)
    // Diagonal correlation outputs (8-connected extension)
    output reg           v_ne = 1'b0,     // correlation from NE neighbor (NE motion)
    output reg           v_nw = 1'b0,     // correlation from NW neighbor (NW motion)
    output reg           v_se = 1'b0,     // correlation from SE neighbor (SE motion)
    output reg           v_sw = 1'b0,     // correlation from SW neighbor (SW motion)
    // Pass-through coordinates
    output reg [XW-1:0]  x_tap = {XW{1'b0}},    // current event x coordinate (pass-through)
    output reg [YW-1:0]  y_tap = {YW{1'b0}},    // current event y coordinate (pass-through)
    output reg           pol_tap = 1'b0   // current event polarity (pass-through)
);
    // Use at least 1 bit for pointer to avoid zero-width issues
    localparam PTR_W = (DW > 0) ? DW : 1;
    localparam DEPTH = (1 << DW);

    // Ring buffer: single write pointer, read from same location (oldest entry)
    reg [PTR_W-1:0] wptr;

    // Event storage
    reg          buf_v [0:DEPTH-1];
    reg [XW-1:0] buf_x [0:DEPTH-1];
    reg [YW-1:0] buf_y [0:DEPTH-1];

    // Combinational read of delayed event (oldest entry at wptr)
    // This is read BEFORE the write in the same cycle
    wire          rd_v = buf_v[wptr];
    wire [XW-1:0] rd_x = buf_x[wptr];
    wire [YW-1:0] rd_y = buf_y[wptr];

    // Boundary constants for safe neighbor comparisons
    localparam [XW-1:0] X_MAX = {XW{1'b1}};
    localparam [YW-1:0] Y_MAX = {YW{1'b1}};
    // Parameterized step size (cast to match port width)
    localparam [XW-1:0] XSTEP = STEP[XW-1:0];
    localparam [YW-1:0] YSTEP = STEP[YW-1:0];

    // Spatial correlation with boundary-safe neighbor checks
    // Boundary: safe to add/subtract STEP without wrap
    wire in_x_not_max = (in_x <= X_MAX - XSTEP);
    wire in_x_not_min = (in_x >= XSTEP);
    wire in_y_not_max = (in_y <= Y_MAX - YSTEP);
    wire in_y_not_min = (in_y >= YSTEP);

    // Cardinal match conditions with boundary guards
    wire match_e = rd_v && in_x_not_max && (rd_x == in_x + XSTEP) && (rd_y == in_y);
    wire match_w = rd_v && in_x_not_min && (rd_x == in_x - XSTEP) && (rd_y == in_y);
    wire match_n = rd_v && in_y_not_max && (rd_x == in_x) && (rd_y == in_y + YSTEP);
    wire match_s = rd_v && in_y_not_min && (rd_x == in_x) && (rd_y == in_y - YSTEP);

    // Diagonal match conditions with boundary guards
    // NE: delayed was at (x+STEP, y+STEP), motion toward NE
    wire match_ne = rd_v && in_x_not_max && in_y_not_max &&
                    (rd_x == in_x + XSTEP) && (rd_y == in_y + YSTEP);
    // NW: delayed was at (x-STEP, y+STEP), motion toward NW
    wire match_nw = rd_v && in_x_not_min && in_y_not_max &&
                    (rd_x == in_x - XSTEP) && (rd_y == in_y + YSTEP);
    // SE: delayed was at (x+STEP, y-STEP), motion toward SE
    wire match_se = rd_v && in_x_not_max && in_y_not_min &&
                    (rd_x == in_x + XSTEP) && (rd_y == in_y - YSTEP);
    // SW: delayed was at (x-STEP, y-STEP), motion toward SW
    wire match_sw = rd_v && in_x_not_min && in_y_not_min &&
                    (rd_x == in_x - XSTEP) && (rd_y == in_y - YSTEP);

    // Buffer initialization
    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1) begin
            buf_v[i] = 1'b0;
            buf_x[i] = {XW{1'b0}};
            buf_y[i] = {YW{1'b0}};
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            wptr <= {PTR_W{1'b0}};
            // Cardinal outputs
            v_e <= 1'b0;
            v_w <= 1'b0;
            v_n <= 1'b0;
            v_s <= 1'b0;
            // Diagonal outputs
            v_ne <= 1'b0;
            v_nw <= 1'b0;
            v_se <= 1'b0;
            v_sw <= 1'b0;
            // Coordinate pass-through
            x_tap <= {XW{1'b0}};
            y_tap <= {YW{1'b0}};
            pol_tap <= 1'b0;
            // Reset buffer valid flags (buf_x/buf_y don't need reset, just v)
            for (i = 0; i < DEPTH; i = i + 1) begin
                buf_v[i] <= 1'b0;
            end
        end else begin
            // Default: no correlation output
            v_e <= 1'b0;
            v_w <= 1'b0;
            v_n <= 1'b0;
            v_s <= 1'b0;
            v_ne <= 1'b0;
            v_nw <= 1'b0;
            v_se <= 1'b0;
            v_sw <= 1'b0;

            if (in_valid) begin
                // Output cardinal correlation results
                v_e <= match_e;
                v_w <= match_w;
                v_n <= match_n;
                v_s <= match_s;
                // Output diagonal correlation results
                v_ne <= match_ne;
                v_nw <= match_nw;
                v_se <= match_se;
                v_sw <= match_sw;

                // Pass through current event coordinates
                x_tap <= in_x;
                y_tap <= in_y;
                pol_tap <= in_pol;

                // Write current event to ring buffer (overwrites oldest entry)
                buf_v[wptr] <= 1'b1;
                buf_x[wptr] <= in_x;
                buf_y[wptr] <= in_y;

                // Advance write pointer.
                // For DW=0 (DEPTH=1) wptr must stay at 0; a plain +1 would reach index 1
                // which is out-of-bounds for a 1-element array and returns 1'bx in simulation.
                // The conditional is resolved at elaboration time and optimised away by synthesis.
                wptr <= (DEPTH > 1) ? wptr + 1'b1 : {PTR_W{1'b0}};
            end
        end
    end
endmodule

`default_nettype wire
