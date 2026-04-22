`timescale 1ns/1ps
`default_nettype none

module tb_pred_valid_golden;
    localparam T_NS = 10;
    localparam XW = 10;
    localparam YW = 10;
    localparam AW = 8;
    localparam DW = 4;
    localparam PW = 16;

    reg clk = 0;
    reg rst = 1;
    always #(T_NS/2) clk = ~clk;

    // Configurable stimulus knobs via plusargs
    integer reset_cycles = 64;
    integer quiet_cycles = 32;
    integer tail_cycles  = 256;
    integer event_count  = 64;
    integer event_spacing = 1;
    integer base_x = 32;
    integer base_y = 48;
    integer x_step = 1;
    integer y_step = 0;
    integer y_wiggle = 0;
    integer pol_toggle = 0;
    reg [255:0] test_name = "gp";

    initial begin
        void'($value$plusargs("RESET_CYCLES=%d", reset_cycles));
        void'($value$plusargs("QUIET_CYCLES=%d", quiet_cycles));
        void'($value$plusargs("TAIL_CYCLES=%d", tail_cycles));
        void'($value$plusargs("EVENT_COUNT=%d", event_count));
        void'($value$plusargs("EVENT_SPACING=%d", event_spacing));
        void'($value$plusargs("BASE_X=%d", base_x));
        void'($value$plusargs("BASE_Y=%d", base_y));
        void'($value$plusargs("X_STEP=%d", x_step));
        void'($value$plusargs("Y_STEP=%d", y_step));
        void'($value$plusargs("Y_WIGGLE=%d", y_wiggle));
        void'($value$plusargs("POL_TOGGLE=%d", pol_toggle));
        void'($value$plusargs("TEST_NAME=%s", test_name));
    end

    // DUT interface
    reg aer_req = 0;
    wire aer_ack;
    reg [XW-1:0] aer_x = 0;
    reg [YW-1:0] aer_y = 0;
    reg aer_pol = 0;
    reg [AW-1:0] scan = 0;
    always @(posedge clk) if (!rst) scan <= scan + 1'b1;

    wire pred_valid;
    wire [PW-1:0] x_hat;
    wire [PW-1:0] y_hat;
    wire [7:0] conf;
    wire conf_valid;

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
        .conf_valid(conf_valid)
    );

    integer events_sent = 0;
    integer pred_valid_count = 0;
    integer first_pred_cycle = -1;
    integer sim_cycle = 0;
    always @(posedge clk) begin
        if (rst) sim_cycle <= 0;
        else sim_cycle <= sim_cycle + 1;
    end

    always @(posedge clk) begin
        if (!rst && pred_valid) begin
            pred_valid_count <= pred_valid_count + 1;
            if (first_pred_cycle < 0)
                first_pred_cycle <= sim_cycle;
        end
    end

    task automatic emit_event(input integer cyc_idx);
        integer x_val;
        integer y_val;
        begin
            x_val = base_x + cyc_idx * x_step;
            y_val = base_y + cyc_idx * y_step;
            if (y_wiggle && (cyc_idx % 2))
                y_val = base_y + 2;
            aer_x <= x_val[XW-1:0];
            aer_y <= y_val[YW-1:0];
            if (pol_toggle)
                aer_pol <= (cyc_idx % 2);
            aer_req <= 1'b1;
            @(negedge clk);
            aer_req <= 1'b0;
            events_sent = events_sent + 1;
        end
    endtask

    initial begin : stimulus
        integer i;
        repeat (reset_cycles) @(negedge clk);
        rst = 0;
        repeat (quiet_cycles) @(negedge clk);
        for (i = 0; i < event_count; i = i + 1) begin
            repeat (event_spacing) @(negedge clk);
            emit_event(i);
        end
        repeat (tail_cycles) @(negedge clk);
        $display("PHASE1_RESULT test=%0s pred_count=%0d first_cycle=%0d events_sent=%0d total_cycle=%0d",
                 test_name, pred_valid_count, first_pred_cycle, events_sent, sim_cycle);
        $finish;
    end
endmodule

`default_nettype wire
