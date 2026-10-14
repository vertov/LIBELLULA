`timescale 1ns/1ps
`default_nettype none

module tb_benchmark_driver;
    localparam T_NS = 10;  // Match tb_cv_linear clock
    localparam XW = 10;
    localparam YW = 10;
    localparam AW = 8;
    localparam DW = 4;
    localparam PW = 16;

    reg clk = 0;
    reg rst = 1;
    always #(T_NS/2) clk = ~clk;

    // AER interface
    reg aer_req = 0;
    wire aer_ack;
    reg [XW-1:0] aer_x = 0;
    reg [YW-1:0] aer_y = 0;
    reg aer_pol = 0;
    reg [AW-1:0] scan = 0;
    reg scan_override_valid = 0;
    reg [AW-1:0] scan_override_value = 0;
    always @(posedge clk) begin
        if (rst) begin
            scan <= {AW{1'b0}};
            scan_override_valid <= 0;
        end else if (scan_override_valid) begin
            scan <= scan_override_value;
            scan_override_valid <= 0;
        end else begin
            scan <= scan + 1'b1;
        end
    end

    wire pred_valid;
    wire [PW-1:0] x_hat;
    wire [PW-1:0] y_hat;
    wire [7:0] conf;
    wire conf_valid;

    wire [1:0] tid_unused;
    libellula_top #(.XW(XW), .YW(YW), .AW(AW), .DW(DW), .PW(PW)) dut (
        .clk(clk),
        .rst(rst),
        .aer_req(aer_req),
        .aer_ack(aer_ack),
        .aer_x(aer_x),
        .aer_y(aer_y),
        .aer_pol(aer_pol),
        .scan_addr(scan),
        .pred_valid(pred_valid),
        .x_hat(x_hat),
        .y_hat(y_hat),
        .conf(conf),
        .conf_valid(conf_valid),
        .track_id(tid_unused)
    );

    // File IO
    integer events_fd;
    integer pred_fd;
    reg [1023:0] events_path;
    reg [1023:0] pred_path;
    integer max_cycles = 2048;
    integer flush_cycles = 64;

    // Cycle tracking
    integer sim_cycle = 0;
    always @(posedge clk) begin
        if (rst) sim_cycle <= 0;
        else sim_cycle <= sim_cycle + 1;
    end

    reg feed_done = 0;
    integer events_processed = 0;
    integer last_event_cycle_sent = 0;

    // Prediction-to-event pairing (v23).
    // The core does NOT emit one prediction per input event: under default
    // parameters the burst gate passes only a fraction of events to the
    // predictor. Each prediction is therefore labelled with the MOST RECENT
    // event presented to the core before pred_valid, i.e. the newest
    // information the core could have used. latency_cycles is measured from
    // that event. (v22 and earlier popped a FIFO, pairing prediction k with
    // event k, which mislabelled every prediction after the first.)
    // An event presented fewer than PIPE_LAT cycles before pred_valid cannot
    // have produced it (fixed pipeline depth; 6 in this driver's counting
    // convention = tb_latency's 5 cycles + the negedge launch offset), so the
    // pairing skips such events using a short history ring.
    localparam integer PIPE_LAT = 6;
    localparam integer HIST = 16;
    integer hist_sim  [0:HIST-1];
    integer hist_scen [0:HIST-1];
    integer hist_n = 0;

    initial begin
        if (!$value$plusargs("EVENTS=%s", events_path)) begin
            $display("Missing +EVENTS=<path> plusarg");
            $finish_and_return(1);
        end
        if (!$value$plusargs("PRED_OUT=%s", pred_path)) begin
            $display("Missing +PRED_OUT=<path> plusarg");
            $finish_and_return(1);
        end
        if ($value$plusargs("MAX_CYCLES=%d", max_cycles)) begin end
        if ($value$plusargs("FLUSH=%d", flush_cycles)) begin end

        events_fd = $fopen(events_path, "r");
        if (events_fd == 0) begin
            $display("Failed to open events file: %s", events_path);
            $finish_and_return(1);
        end
        pred_fd = $fopen(pred_path, "w");
        if (pred_fd == 0) begin
            $display("Failed to open prediction output: %s", pred_path);
            $finish_and_return(1);
        end
        $fwrite(pred_fd, "sim_cycle,scenario_cycle,x_hat,y_hat,conf,latency_cycles\n");
        #(20*T_NS);
        rst = 0;
    end

    initial begin : feeder
        integer event_cycle;
        integer scenario_cycle;
        integer event_x;
        integer event_y;
        integer event_pol;
        integer status;
        integer total_events = 0;
        integer idx;
        integer hashed_addr;
        wait(!rst);
        status = $fscanf(events_fd, "%d\n", total_events);
        if (status != 1) begin
            $display("Failed to read event count from %s", events_path);
            $finish_and_return(1);
        end
        begin : feed_loop
            for (idx = 0; idx < total_events; idx = idx + 1) begin
                status = $fscanf(events_fd, "%d,%d,%d,%d,%d\n", event_cycle, scenario_cycle, event_x, event_y, event_pol);
                if (status != 5) begin
                    $display("Malformed event line at index %0d", idx);
                    disable feed_loop;
                end
                while (sim_cycle < event_cycle) @(posedge clk);
                @(negedge clk);
                hashed_addr = {event_x[XW-1:XW-AW/2], event_y[YW-1:YW-(AW-AW/2)]};
                scan_override_value <= hashed_addr[AW-1:0];
                scan_override_valid <= 1'b1;
                aer_x <= event_x[XW-1:0];
                aer_y <= event_y[YW-1:0];
                aer_pol <= event_pol[0];
                aer_req <= 1'b1;
                last_event_cycle_sent = event_cycle;
                hist_sim[hist_n % HIST]  = sim_cycle;
                hist_scen[hist_n % HIST] = scenario_cycle;
                hist_n = hist_n + 1;
                @(negedge clk);
                aer_req <= 1'b0;
                events_processed = events_processed + 1;
            end
        end
        feed_done = 1;
    end

    // Capture predictions
    always @(posedge clk) begin
        if (!rst && pred_valid) begin
            integer evt_sim;
            integer evt_scen;
            integer latency;
            integer k;
            integer found;
            found = 0;
            evt_sim = sim_cycle;
            evt_scen = 0;
            for (k = 1; k <= HIST && !found; k = k + 1) begin
                if (hist_n - k >= 0) begin
                    if (sim_cycle - hist_sim[(hist_n - k) % HIST] >= PIPE_LAT) begin
                        evt_sim  = hist_sim[(hist_n - k) % HIST];
                        evt_scen = hist_scen[(hist_n - k) % HIST];
                        found = 1;
                    end
                end
            end
            latency = sim_cycle - evt_sim;
            $fwrite(pred_fd, "%0d,%0d,%0d,%0d,%0d,%0d\n",
                    sim_cycle,
                    evt_scen,
                    $signed(x_hat),
                    $signed(y_hat),
                    conf,
                    latency);
        end
    end

    // Watchdog and graceful finish
    initial begin : watchdog
        wait(sim_cycle >= max_cycles);
        $display("Max cycles %0d reached (events=%0d feed_done=%0d)", max_cycles, events_processed, feed_done);
        $finish_and_return(1);
    end

    initial begin : shutdown
        wait(feed_done);
        repeat (flush_cycles) @(negedge clk);
        $fclose(events_fd);
        $fclose(pred_fd);
        $display("Benchmark run complete");
        $finish;
    end
endmodule

`default_nettype wire
