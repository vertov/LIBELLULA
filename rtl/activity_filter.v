`timescale 1ns/1ps
`default_nettype none

// Spatiotemporal background-activity filter (BAF).
//
// Passes an event only if its tile, or one of the 8 neighbouring tiles, has
// seen activity within (approximately) the last WINDOW cycles. Isolated
// noise events (no recent spatial support) are dropped before they can
// charge LIF neurons, pollute the delay-lattice window, or bias the
// Reichardt accumulator. A hot pixel's events keep only its OWN tile fresh,
// so after the first event a stuck pixel self-supports; pair with LIF leak
// for full rejection, or extend with a per-tile rate cap if hot pixels
// dominate a deployment.
//
// SEMANTICS:
// - The filter tracks per-tile recency (same {x_hi, y_hi} concatenation
//   hash as lif_tile_tmux, so "tile" means the same thing pipeline-wide).
// - support = own tile OR any 8-neighbour tile recently active. The current
//   event does NOT count as its own support: the very first event in a
//   silent region is always dropped. Real targets emit dense event
//   clusters, so this costs one event per cold region.
// - Every in_valid event marks its tile active, INCLUDING dropped events:
//   two isolated noise events in the same tile within the window let the
//   second one through. Standard BAF behaviour — true isolated noise is
//   Poisson and rarely doubles up in one tile-window.
// - EN=0 makes the filter fully transparent (combinational pass-through,
//   zero latency, no behavioural change) so existing configurations and
//   benches are unaffected unless the filter is explicitly enabled.
//
// LATENCY: zero cycles. The pass/drop decision is combinational on the
// event path; only the recency bookkeeping is clocked. The top-level
// +1..+5 stage timing contract is unchanged.
//
// EXPIRY GRANULARITY: recency is a flat bit-map (recent_map) set on event
// arrival and cleared by a background scrubber that compares per-tile
// timestamps against WINDOW, visiting one tile per cycle. A tile therefore
// expires between WINDOW and WINDOW + 2^AW cycles after its last event —
// choose WINDOW with that +2^AW overhang in mind. The bit-map (a single
// vector, not an array) is what the combinational support expression reads,
// which keeps the logic synthesisable and gives simulators correct
// re-evaluation semantics; timestamps are only ever read in the clocked
// scrubber.
//
// COST NOTE (synthesis): recent_map is 2^AW flops with 9 combinational
// read taps — trivial fabric. The timestamp memory (2^AW x TW) has one
// write and one (scrubber) read port and maps to a plain dual-port RAM.
module activity_filter #(
    parameter XW=10, YW=10,
    parameter AW=8,           // tile address width (must match lif_tile_tmux)
    parameter TW=16,          // timestamp width in bits
    parameter WINDOW=2048,    // spatial-support window in clock cycles (+2^AW overhang)
    parameter EN=0            // 0 = transparent pass-through; 1 = filter active
)(
    input  wire          clk, rst,
    input  wire          in_valid,
    input  wire [XW-1:0] in_x,
    input  wire [YW-1:0] in_y,
    input  wire          in_pol,
    output wire          out_valid,
    output wire [XW-1:0] out_x,
    output wire [YW-1:0] out_y,
    output wire          out_pol,
    output wire          dropped     // diagnostics: event rejected this cycle
);
    // Same tile hash split as lif_tile_tmux
    localparam HX = AW / 2;
    localparam HY = AW - HX;

    wire [HX-1:0] tx = in_x[XW-1:XW-HX];
    wire [HY-1:0] ty = in_y[YW-1:YW-HY];

    localparam [HX-1:0] TX_MAX = {HX{1'b1}};
    localparam [HY-1:0] TY_MAX = {HY{1'b1}};

    reg [TW-1:0]        now = {TW{1'b0}};
    reg [(1<<AW)-1:0]   recent_map = {(1<<AW){1'b0}};
    reg [TW-1:0]        last_seen [0:(1<<AW)-1];

    integer i;
    initial begin
        for (i = 0; i < (1 << AW); i = i + 1)
            last_seen[i] = {TW{1'b0}};
    end

    // Spatial support: own tile or any 8-neighbour, boundary-guarded (no wrap)
    wire support =
        recent_map[{tx, ty}]
     || ((tx < TX_MAX)                  && recent_map[{tx + 1'b1, ty}])
     || ((tx > {HX{1'b0}})              && recent_map[{tx - 1'b1, ty}])
     || ((ty < TY_MAX)                  && recent_map[{tx, ty + 1'b1}])
     || ((ty > {HY{1'b0}})              && recent_map[{tx, ty - 1'b1}])
     || ((tx < TX_MAX) && (ty < TY_MAX) && recent_map[{tx + 1'b1, ty + 1'b1}])
     || ((tx > {HX{1'b0}}) && (ty < TY_MAX) && recent_map[{tx - 1'b1, ty + 1'b1}])
     || ((tx < TX_MAX) && (ty > {HY{1'b0}}) && recent_map[{tx + 1'b1, ty - 1'b1}])
     || ((tx > {HX{1'b0}}) && (ty > {HY{1'b0}}) && recent_map[{tx - 1'b1, ty - 1'b1}]);

    assign out_valid = in_valid && ((EN == 0) || support);
    assign out_x     = in_x;
    assign out_y     = in_y;
    assign out_pol   = in_pol;
    assign dropped   = in_valid && !out_valid;

    // Recency bookkeeping + stale-entry scrubber (one tile per cycle).
    // The event write is last in the block, so it wins over the scrubber
    // when both target the same tile in one cycle.
    reg [AW-1:0] scrub = {AW{1'b0}};

    always @(posedge clk) begin
        if (rst) begin
            now        <= {TW{1'b0}};
            scrub      <= {AW{1'b0}};
            recent_map <= {(1 << AW){1'b0}};
            // last_seen needs no reset: recent_map gates every read of it,
            // and an event re-writes its tile's timestamp before the bit is
            // ever set again.
        end else begin
            now   <= now + 1'b1;
            scrub <= scrub + 1'b1;
            if (recent_map[scrub] && ((now - last_seen[scrub]) > WINDOW[TW-1:0]))
                recent_map[scrub] <= 1'b0;
            if (in_valid) begin
                last_seen[{tx, ty}]  <= now;
                recent_map[{tx, ty}] <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
