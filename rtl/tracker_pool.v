`timescale 1ns/1ps
`default_nettype none

// Tracker pool: N independent alpha-beta predictors with measurement routing.
//
// ASSIGNMENT (per in_valid):
//   1. Compute L1 distance from measurement to each ACTIVE tracker's last output.
//   2. Assign to nearest active tracker within ASSIGN_TH pixels.
//   3. If no match: spawn nearest IDLE tracker (cold start).
//   4. Exactly one tracker receives in_valid per event.
//
// COAST TIMEOUT:
//   Each in_valid event NOT assigned to a tracker increments that tracker's
//   coast counter. After COAST_TIMEOUT misses, the tracker is retired (idle).
//
// OUTPUT:
//   Whichever predictor was just updated fires out_valid the following cycle.
//   track_id identifies which tracker fired.
//
// NOTE: N=4, IDW=2 are the only validated values. The packed-bus slicing
// uses runtime indexing which Icarus Verilog 12 supports in SystemVerilog mode.
module tracker_pool #(
    parameter XW            = 10,
    parameter YW            = 10,
    parameter PW            = 16,
    parameter N             = 4,
    parameter IDW           = 2,
    parameter ASSIGN_TH     = 96,
    parameter COAST_TIMEOUT = 4,
    parameter OUTLIER_TH    = 128,
    parameter VEL_INIT      = 0,
    parameter VEL_SAT_MAX   = 64
)(
    input  wire clk, rst,
    input  wire in_valid,
    input  wire [XW-1:0] in_x,
    input  wire [YW-1:0] in_y,
    input  wire signed [7:0] dir_x,
    input  wire signed [7:0] dir_y,
    output reg  out_valid               = 1'b0,
    output reg  [PW-1:0] x_hat         = {PW{1'b0}},
    output reg  [PW-1:0] y_hat         = {PW{1'b0}},
    output reg  [IDW-1:0] track_id     = {IDW{1'b0}}
);

    // =========================================================================
    // ALL DECLARATIONS (before any procedural blocks)
    // =========================================================================

    // Packed buses: tracker i uses bits [(i+1)*PW-1 : i*PW]
    wire [N*PW-1:0] pred_x_bus;
    wire [N*PW-1:0] pred_y_bus;
    wire [N-1:0]    pred_v_bus;

    // Per-tracker routing signals
    reg  [N-1:0]    in_v_bus;
    reg  [N-1:0]    soft_rst_bus;
    reg  [N-1:0]    retiring = {N{1'b0}};  // one-cycle retirement pulse → soft_rst

    // Per-tracker state
    reg        active    [0:N-1];
    reg [3:0]  coast_cnt [0:N-1];

    // Cached position of each tracker (updated when its predictor fires)
    reg [PW-1:0] cached_x [0:N-1];
    reg [PW-1:0] cached_y [0:N-1];

    // Distance computation temporaries (in combinational always)
    reg [PW:0]   l1dist       [0:N-1];  // renamed: 'dist' is a SystemVerilog keyword
    reg [PW-1:0] dx_tmp;
    reg [PW-1:0] dy_tmp;

    // Best-tracker search outputs
    reg [IDW-1:0] best_active_id;
    reg           found_active;
    reg [PW:0]    best_active_dist;
    reg [IDW-1:0] best_idle_id;
    reg           found_idle;

    // Loop variables
    integer ci, di, ai, ri, si, oi;

    // Assignment result (combinational)
    wire [IDW-1:0] assigned_id    = found_active ? best_active_id :
                                     found_idle   ? best_idle_id   :
                                                    {IDW{1'b0}};
    wire           has_assignment = found_active || found_idle;

    // =========================================================================
    // Cache predictor positions whenever they fire
    // =========================================================================
    always @(posedge clk) begin
        if (rst) begin
            for (ci = 0; ci < N; ci = ci + 1) begin
                cached_x[ci] <= {PW{1'b0}};
                cached_y[ci] <= {PW{1'b0}};
            end
        end else begin
            for (ci = 0; ci < N; ci = ci + 1) begin
                if (pred_v_bus[ci]) begin
                    cached_x[ci] <= pred_x_bus[(ci+1)*PW-1 -: PW];
                    cached_y[ci] <= pred_y_bus[(ci+1)*PW-1 -: PW];
                end
            end
        end
    end

    // =========================================================================
    // L1 distance computation (combinational)
    // =========================================================================
    always @(*) begin
        for (di = 0; di < N; di = di + 1) begin
            dx_tmp  = (in_x >= cached_x[di][XW-1:0]) ?
                      (in_x - cached_x[di][XW-1:0]) :
                      (cached_x[di][XW-1:0] - in_x);
            dy_tmp  = (in_y >= cached_y[di][YW-1:0]) ?
                      (in_y - cached_y[di][YW-1:0]) :
                      (cached_y[di][YW-1:0] - in_y);
            l1dist[di] = {1'b0, dx_tmp} + {1'b0, dy_tmp};
        end
    end

    // =========================================================================
    // Find nearest active tracker within ASSIGN_TH, and nearest idle tracker
    // =========================================================================
    always @(*) begin
        best_active_id   = {IDW{1'b0}};
        found_active     = 1'b0;
        best_active_dist = {(PW+1){1'b1}};
        best_idle_id     = {IDW{1'b0}};
        found_idle       = 1'b0;

        for (ai = 0; ai < N; ai = ai + 1) begin
            if (active[ai]) begin
                if (!found_active || l1dist[ai] < best_active_dist) begin
                    best_active_dist = l1dist[ai];
                    best_active_id   = ai[IDW-1:0];
                    found_active     = 1'b1;
                end
            end else begin
                if (!found_idle) begin
                    best_idle_id = ai[IDW-1:0];
                    found_idle   = 1'b1;
                end
            end
        end
        // Discard active match if it exceeds the threshold
        if (found_active && best_active_dist >= ASSIGN_TH)
            found_active = 1'b0;
    end

    // =========================================================================
    // Route in_valid to the assigned tracker
    // soft_rst fires for one cycle when a tracker is being retired (coast timeout).
    // This clears the predictor state so a re-spawned tracker starts fresh.
    // =========================================================================
    always @(*) begin
        in_v_bus     = {N{1'b0}};
        soft_rst_bus = retiring;        // pass retirement pulse as soft_rst
        if (in_valid && has_assignment)
            in_v_bus[assigned_id] = 1'b1;
    end

    // =========================================================================
    // Update active flags, coast counters, and retirement pulse
    // =========================================================================
    always @(posedge clk) begin
        if (rst) begin
            for (si = 0; si < N; si = si + 1) begin
                active[si]    <= 1'b0;
                coast_cnt[si] <= 4'd0;
            end
            retiring <= {N{1'b0}};
        end else begin
            retiring <= {N{1'b0}};  // clear each cycle; set below when retiring
            if (in_valid) begin
                for (si = 0; si < N; si = si + 1) begin
                    if (si[IDW-1:0] == assigned_id && has_assignment) begin
                        active[si]    <= 1'b1;
                        coast_cnt[si] <= 4'd0;
                    end else if (active[si]) begin
                        if (coast_cnt[si] >= (COAST_TIMEOUT - 1)) begin
                            active[si]    <= 1'b0;
                            coast_cnt[si] <= 4'd0;
                            retiring[si]  <= 1'b1;  // triggers soft_rst
                        end else begin
                            coast_cnt[si] <= coast_cnt[si] + 4'd1;
                        end
                    end
                end
            end
        end
    end

    // =========================================================================
    // Output mux: collect whichever predictor just fired
    // (only one in_v fires per event, so only one pred_v fires each cycle)
    // =========================================================================
    always @(posedge clk) begin
        if (rst) begin
            out_valid <= 1'b0;
            x_hat     <= {PW{1'b0}};
            y_hat     <= {PW{1'b0}};
            track_id  <= {IDW{1'b0}};
        end else begin
            out_valid <= 1'b0;
            for (oi = 0; oi < N; oi = oi + 1) begin
                if (pred_v_bus[oi]) begin
                    out_valid <= 1'b1;
                    x_hat     <= pred_x_bus[(oi+1)*PW-1 -: PW];
                    y_hat     <= pred_y_bus[(oi+1)*PW-1 -: PW];
                    track_id  <= oi[IDW-1:0];
                end
            end
        end
    end

    // =========================================================================
    // Predictor instances
    // =========================================================================
    genvar gi;
    generate
        for (gi = 0; gi < N; gi = gi + 1) begin : trackers
            ab_predictor #(
                .XW(XW), .YW(YW), .PW(PW),
                .OUTLIER_TH(OUTLIER_TH),
                .VEL_INIT(VEL_INIT),
                .VEL_SAT_MAX(VEL_SAT_MAX)
            ) u_pred (
                .clk      (clk),
                .rst      (rst),
                .soft_rst (soft_rst_bus[gi]),
                .in_valid (in_v_bus[gi]),
                .in_x     (in_x),
                .in_y     (in_y),
                .dir_x    (dir_x),
                .dir_y    (dir_y),
                .out_valid(pred_v_bus[gi]),
                .x_hat    (pred_x_bus[(gi+1)*PW-1 -: PW]),
                .y_hat    (pred_y_bus[(gi+1)*PW-1 -: PW])
            );
        end
    endgenerate

endmodule

`default_nettype wire
