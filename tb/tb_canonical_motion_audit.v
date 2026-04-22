`timescale 1ns/1ps
`default_nettype none

// Full pipeline propagation audit: injects PATH_LEN scan-aligned events in a
// straight horizontal line and verifies activity at every pipeline stage.
// Requires -DLIBELLULA_DIAG at compile time.
//
// Adapted from CDX tb_canonical_motion_audit for v22:
//   - hash() uses spatial tile hash: {x[XW-1:XW-HX], y[YW-1:YW-HY]}
//     (was XOR hash in CDX; must match lif_tile_tmux's hashed_xy)
//   - dut.u_lif.HIT_WEIGHT replaced with constant 1 (v22 lif_tile_tmux has no
//     HIT_WEIGHT parameter; it always adds 1 per hit)
//   - track_id port connected to tid_unused (v22 libellula_top exposes track_id)
module tb_canonical_motion_audit;
    localparam T_NS = 5;
    localparam XW = 10;
    localparam YW = 10;
    localparam AW = 8;
    localparam DW = 0;
    localparam PW = 16;
    localparam PATH_LEN = 6;
    localparam integer HX = AW / 2;
    localparam integer HY = AW - HX;
    localparam [XW-1:0] X_START = 10'd20;
    localparam [YW-1:0] Y_CONST = 10'd12;

    reg clk = 0;
    reg rst = 1;
    always #(T_NS/2) clk = ~clk;

    // AER interface
    reg aer_req = 0;
    wire aer_ack;
    reg [XW-1:0] aer_x = 0;
    reg [YW-1:0] aer_y = 0;
    reg aer_pol = 0;

    reg [AW-1:0] scan_addr = 0;

    wire pred_valid;
    wire [PW-1:0] x_hat, y_hat;
    wire [7:0] conf;
    wire conf_valid;
    wire [1:0] tid_unused;

    libellula_top #(
        .XW(XW), .YW(YW), .AW(AW), .DW(DW), .PW(PW)
    ) dut (
        .clk(clk), .rst(rst),
        .aer_req(aer_req), .aer_ack(aer_ack),
        .aer_x(aer_x), .aer_y(aer_y), .aer_pol(aer_pol),
        .scan_addr(scan_addr),
        .pred_valid(pred_valid), .x_hat(x_hat), .y_hat(y_hat),
        .conf(conf), .conf_valid(conf_valid),
        .track_id(tid_unused)
    );

    // Spatial tile hash: must match lif_tile_tmux's hashed_xy exactly.
    function automatic [AW-1:0] hash(input [XW-1:0] x, input [YW-1:0] y);
        hash = {x[XW-1:XW-HX], y[YW-1:YW-HY]};
    endfunction

    task automatic wait_cycles(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) @(negedge clk);
        end
    endtask

    reg trace_target_active = 0;
    reg [AW-1:0] trace_target_addr = 0;

    task automatic send_aligned_event(input [XW-1:0] x, input [YW-1:0] y);
        begin
            scan_addr = hash(x, y);
            wait_cycles(2);
            trace_target_addr = hash(x, y);
            trace_target_active = 1;
            @(negedge clk);
            aer_x = x;
            aer_y = y;
            aer_pol = 1'b1;
            aer_req = 1'b1;
            @(negedge clk);
            aer_req = 1'b0;
            wait_cycles(4);
            trace_target_active = 0;
        end
    endtask

    integer cycle = 0;
    always @(posedge clk) begin
        if (rst) cycle <= 0;
        else cycle <= cycle + 1;
    end

    integer ev_first = -1, ev_count = 0;
    integer lif_first = -1, lif_count = 0;
    integer delay_first = -1, delay_count = 0;
    integer dir_first = -1, dir_count = 0;
    integer burst_first = -1, burst_count = 0;
    integer pred_first = -1, pred_count = 0;

    wire delay_activity = dut.v_e | dut.v_w | dut.v_n | dut.v_s |
                          dut.v_ne | dut.v_nw | dut.v_se | dut.v_sw;

    always @(posedge clk) begin
        if (!rst && dut.ev_v) begin
            ev_count <= ev_count + 1;
            if (ev_first < 0) ev_first <= cycle;
        end
        if (!rst && dut.lif_v) begin
            lif_count <= lif_count + 1;
            if (lif_first < 0) lif_first <= cycle;
        end
        if (!rst && delay_activity) begin
            delay_count <= delay_count + 1;
            if (delay_first < 0) delay_first <= cycle;
        end
        if (!rst && dut.ds_v) begin
            dir_count <= dir_count + 1;
            if (dir_first < 0) dir_first <= cycle;
        end
        if (!rst && dut.bg_v) begin
            burst_count <= burst_count + 1;
            if (burst_first < 0) burst_first <= cycle;
        end
        if (!rst && pred_valid) begin
            pred_count <= pred_count + 1;
            if (pred_first < 0) pred_first <= cycle;
        end
    end

    integer trace_enable = 0;
    integer trace_f = 0;
    reg [1023:0] trace_filename = "build/lif_canonical_trace.csv";
    initial begin
        if ($test$plusargs("LIF_TRACE")) begin
            if (!$value$plusargs("TRACE_FILE=%s", trace_filename)) begin
                trace_filename = "build/lif_canonical_trace.csv";
            end
            trace_enable = 1;
            trace_f = $fopen(trace_filename, "w");
            if (trace_f) begin
                $display("LIF_TRACE(canonical): logging to %0s", trace_filename);
                $fwrite(trace_f,"cycle,scan_addr,target_addr,target_active,event_presented,event_accepted,accum_before,leak_amount,hit_weight,accum_after,writeback,threshold,spike\n");
            end else begin
                $display("WARNING: Unable to open %0s", trace_filename);
            end
        end
    end
    final begin
        if (trace_enable && trace_f)
            $fclose(trace_f);
    end
    always @(posedge clk) begin
        if (trace_enable && trace_f && !rst) begin
            $fwrite(trace_f,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                    cycle,
                    scan_addr,
                    trace_target_active ? trace_target_addr : -1,
                    trace_target_active,
                    dut.ev_v,
                    dut.u_lif.hit_s1,
                    dut.u_lif.st_read,
                    dut.u_lif.leak_amount,
                    1,                   // hit_weight is always 1 in v22 lif_tile_tmux
                    dut.u_lif.st_next,
                    dut.u_lif.st_writeback,
                    dut.u_lif.THRESH,
                    dut.u_lif.out_valid);
        end
    end

    integer i;

    initial begin
        repeat (6) @(negedge clk);
        rst = 0;
        wait_cycles(4);
        for (i = 0; i < PATH_LEN; i = i + 1) begin
            send_aligned_event(X_START + i[9:0], Y_CONST);
        end
        wait_cycles(80);
        $display("CANONICAL_SUMMARY events_presented=%0d events_accepted=%0d lif_updates=%0d lif_spikes=%0d dir_count=%0d burst_count=%0d pred_valid_count=%0d",
                 dut.u_lif.events_presented,
                 dut.u_lif.events_accepted,
                 dut.u_lif.lif_updates,
                 dut.u_lif.lif_spikes,
                 dir_count,
                 burst_count,
                 pred_count);
        $display("E2E_SUMMARY,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                 ev_first, lif_first, delay_first, dir_first,
                 burst_first, pred_first,
                 ev_count, pred_count,
                 (pred_first >= 0 && ev_first >= 0) ? (pred_first - ev_first) : -1);
        $finish;
    end
endmodule

`default_nettype wire
