`timescale 1ns/1ps
`default_nettype none

// 8-direction retinotopic delay lattice using a searched ring-buffer window.
//
// -------------------------------------------------------------------------
// REWRITE NOTE (fix/pipeline-rework):
// The previous implementation read only ONE stored entry per event —
// buf[wptr], the single event that arrived exactly DEPTH events ago — so a
// correlation only fired if that one aged sample happened to be a spatial
// neighbour. Raising DW changed *which* single sample was compared, never
// how many. It was a single-tap delay, not a lattice.
//
// This version stores the last DEPTH events and, on each incoming event,
// searches ALL valid slots in parallel for a neighbour match in each of the
// 8 directions (OR-reduction). That is the true "sliding window of the most
// recent DEPTH events" the interface always claimed, and it turns the stage
// into an actual coincidence detector: a direction asserts when the current
// event coincides (within the last DEPTH events) with recent activity at the
// corresponding neighbour tile. Ports and parameters are unchanged, so all
// existing testbenches and the top-level instantiation are unaffected.
//
// Cost: DEPTH parallel neighbour comparators (8 directions each). Keep DEPTH
// (=2^DW) modest for area-constrained targets; DW=4..6 is a sensible range.
// -------------------------------------------------------------------------
//
// DELAY SEMANTICS (event-based):
// - The window holds the most recent DEPTH = 2^DW events (oldest overwritten).
// - Every valid slot is a candidate correlation partner for the current event.
//
// SPATIAL CORRELATION (8-connected neighbourhood, "photoreceptor source"):
// - East:  a windowed event was at (x+STEP, y),      current at (x,y)
// - West:  a windowed event was at (x-STEP, y),      current at (x,y)
// - North: a windowed event was at (x, y+STEP),      current at (x,y)
// - South: a windowed event was at (x, y-STEP),      current at (x,y)
// - NE/NW/SE/SW: the corresponding diagonal neighbours.
//
// BOUNDARY HANDLING:
// - Neighbour comparisons use explicit boundary checks to avoid wrap false
//   positives at the coordinate-space edges.
//
// DW=0 (DEPTH=1): window collapses to the single previous event (legacy
// behaviour), preserved for backward compatibility.
module delay_lattice_rb #(
    parameter XW=10, YW=10, DW=6,   // window depth bits: DEPTH = 2^DW events
    parameter STEP=1                // neighbour step in coordinate units (tile size when tile-hashed)
)(
    input  wire          clk, rst,
    input  wire          in_valid,
    input  wire [XW-1:0] in_x,
    input  wire [YW-1:0] in_y,
    input  wire          in_pol,
    // Cardinal correlation outputs (4-connected)
    output reg           v_e = 1'b0,
    output reg           v_w = 1'b0,
    output reg           v_n = 1'b0,
    output reg           v_s = 1'b0,
    // Diagonal correlation outputs (8-connected extension)
    output reg           v_ne = 1'b0,
    output reg           v_nw = 1'b0,
    output reg           v_se = 1'b0,
    output reg           v_sw = 1'b0,
    // Pass-through coordinates
    output reg [XW-1:0]  x_tap = {XW{1'b0}},
    output reg [YW-1:0]  y_tap = {YW{1'b0}},
    output reg           pol_tap = 1'b0
);
    localparam PTR_W = (DW > 0) ? DW : 1;
    localparam DEPTH = (1 << DW);

    // Sliding window of the most recent DEPTH events.
    reg [PTR_W-1:0] wptr;
    reg          buf_v [0:DEPTH-1];
    reg [XW-1:0] buf_x [0:DEPTH-1];
    reg [YW-1:0] buf_y [0:DEPTH-1];

    // Boundary constants / parameterised step
    localparam [XW-1:0] X_MAX  = {XW{1'b1}};
    localparam [YW-1:0] Y_MAX  = {YW{1'b1}};
    localparam [XW-1:0] XSTEP  = STEP[XW-1:0];
    localparam [YW-1:0] YSTEP  = STEP[YW-1:0];

    wire in_x_not_max = (in_x <= X_MAX - XSTEP);
    wire in_x_not_min = (in_x >= XSTEP);
    wire in_y_not_max = (in_y <= Y_MAX - YSTEP);
    wire in_y_not_min = (in_y >= YSTEP);

    // Parallel search of the whole window: a direction matches if ANY valid
    // slot holds the corresponding neighbour of the current event.
    reg m_e, m_w, m_n, m_s, m_ne, m_nw, m_se, m_sw;
    integer j;
    always @* begin
        m_e = 1'b0; m_w = 1'b0; m_n = 1'b0; m_s = 1'b0;
        m_ne = 1'b0; m_nw = 1'b0; m_se = 1'b0; m_sw = 1'b0;
        for (j = 0; j < DEPTH; j = j + 1) begin
            if (buf_v[j]) begin
                // Cardinal
                if (in_x_not_max && (buf_x[j] == in_x + XSTEP) && (buf_y[j] == in_y)) m_e = 1'b1;
                if (in_x_not_min && (buf_x[j] == in_x - XSTEP) && (buf_y[j] == in_y)) m_w = 1'b1;
                if (in_y_not_max && (buf_x[j] == in_x) && (buf_y[j] == in_y + YSTEP)) m_n = 1'b1;
                if (in_y_not_min && (buf_x[j] == in_x) && (buf_y[j] == in_y - YSTEP)) m_s = 1'b1;
                // Diagonal
                if (in_x_not_max && in_y_not_max && (buf_x[j] == in_x + XSTEP) && (buf_y[j] == in_y + YSTEP)) m_ne = 1'b1;
                if (in_x_not_min && in_y_not_max && (buf_x[j] == in_x - XSTEP) && (buf_y[j] == in_y + YSTEP)) m_nw = 1'b1;
                if (in_x_not_max && in_y_not_min && (buf_x[j] == in_x + XSTEP) && (buf_y[j] == in_y - YSTEP)) m_se = 1'b1;
                if (in_x_not_min && in_y_not_min && (buf_x[j] == in_x - XSTEP) && (buf_y[j] == in_y - YSTEP)) m_sw = 1'b1;
            end
        end
    end

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
            v_e <= 1'b0; v_w <= 1'b0; v_n <= 1'b0; v_s <= 1'b0;
            v_ne <= 1'b0; v_nw <= 1'b0; v_se <= 1'b0; v_sw <= 1'b0;
            x_tap <= {XW{1'b0}};
            y_tap <= {YW{1'b0}};
            pol_tap <= 1'b0;
            for (i = 0; i < DEPTH; i = i + 1) begin
                buf_v[i] <= 1'b0;
            end
        end else begin
            // Default: no correlation output
            v_e <= 1'b0; v_w <= 1'b0; v_n <= 1'b0; v_s <= 1'b0;
            v_ne <= 1'b0; v_nw <= 1'b0; v_se <= 1'b0; v_sw <= 1'b0;

            if (in_valid) begin
                // Register windowed-search results
                v_e <= m_e; v_w <= m_w; v_n <= m_n; v_s <= m_s;
                v_ne <= m_ne; v_nw <= m_nw; v_se <= m_se; v_sw <= m_sw;

                // Pass through current event coordinates
                x_tap <= in_x;
                y_tap <= in_y;
                pol_tap <= in_pol;

                // Insert current event into the window (overwrite oldest)
                buf_v[wptr] <= 1'b1;
                buf_x[wptr] <= in_x;
                buf_y[wptr] <= in_y;

                // Advance write pointer. DW=0 (DEPTH=1) pins wptr at 0.
                wptr <= (DEPTH > 1) ? wptr + 1'b1 : {PTR_W{1'b0}};
            end
        end
    end
endmodule

`default_nettype wire
