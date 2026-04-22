// =============================================================================
// axi4s_pred_wrapper.v
// AXI4-Stream output wrapper for LIBELLULA Core v22
//
// Bridges LIBELLULA's pred_valid / (x_pred, y_pred, conf) outputs to an
// AXI4-Stream master interface.  Sits between libellula_top and any AXI4-S
// downstream consumer (DMA, SoC fabric, FPGA IP core, etc.).
//
// TDATA packing (48-bit / 6 bytes):
//   [47:40]  8'b0        padding (reserved)
//   [39:32]  conf        confidence byte
//   [31:16]  y_pred      Q8.8 Y prediction
//   [15: 0]  x_pred      Q8.8 X prediction
//
// Back-pressure and multi-target burst:
//   An internal FIFO (depth FIFO_DEPTH, default 4) absorbs predictions that
//   arrive while the AXI output is stalled.  With NTRACK=4, up to 4 trackers
//   can fire in rapid succession; the FIFO guarantees no prediction is silently
//   overwritten.  A fast path bypasses the FIFO when the output register is
//   free, preserving single-prediction latency.
//   If the FIFO fills (>FIFO_DEPTH predictions queued), the newest prediction
//   is dropped and a simulation warning is emitted.
//
// ARM IHI 0051A compliance:
//   TVALID deasserts only after TREADY handshake.
//   TKEEP = 6'b111111 (all 6 payload bytes always valid).
//   TLAST = TVALID (single-beat frame per prediction).
// =============================================================================

`timescale 1ns/1ps

module axi4s_pred_wrapper #(
    parameter PW         = 16,   // Prediction coordinate width  (match libellula_top)
    parameter CONFW      =  8,   // Confidence output width      (match conf_gate)
    parameter FIFO_DEPTH =  4    // Overflow FIFO depth (power of 2; match NTRACK)
)(
    input  wire              clk,
    input  wire              rst_n,

    // -------------------------------------------------------------------------
    // LIBELLULA core outputs  (connect directly to libellula_top ports)
    // -------------------------------------------------------------------------
    input  wire              pred_valid,   // one-cycle strobe when prediction ready
    input  wire [PW-1:0]     x_pred,       // Q8.8 X coordinate
    input  wire [PW-1:0]     y_pred,       // Q8.8 Y coordinate
    input  wire [CONFW-1:0]  conf,         // confidence score

    // -------------------------------------------------------------------------
    // AXI4-Stream master  (connect to downstream DMA / SoC fabric)
    // -------------------------------------------------------------------------
    output reg               m_axis_tvalid,
    input  wire              m_axis_tready,
    output reg  [47:0]       m_axis_tdata,
    output wire [5:0]        m_axis_tkeep,  // all 6 bytes always valid
    output wire              m_axis_tlast   // single-beat frame per prediction
);

    assign m_axis_tkeep = 6'b111111;
    assign m_axis_tlast = m_axis_tvalid;

    // -------------------------------------------------------------------------
    // Packed prediction word (combinational)
    // -------------------------------------------------------------------------
    wire [47:0] pred_word = {8'd0, conf[CONFW-1:0], y_pred[PW-1:0], x_pred[PW-1:0]};

    // -------------------------------------------------------------------------
    // Overflow FIFO  (absorbs bursts when output register is stalled)
    // FIFO_DEPTH must be a power of 2.  Address width = $clog2(FIFO_DEPTH).
    // Pointer scheme: one extra bit for full/empty disambiguation.
    // -------------------------------------------------------------------------
    localparam FIFO_AW = $clog2(FIFO_DEPTH);

    reg [47:0]      fifo_mem [0:FIFO_DEPTH-1];
    reg [FIFO_AW:0] wr_ptr = {(FIFO_AW+1){1'b0}};
    reg [FIFO_AW:0] rd_ptr = {(FIFO_AW+1){1'b0}};

    wire fifo_empty = (wr_ptr == rd_ptr);
    wire fifo_full  = (wr_ptr[FIFO_AW] != rd_ptr[FIFO_AW]) &&
                      (wr_ptr[FIFO_AW-1:0] == rd_ptr[FIFO_AW-1:0]);

    // -------------------------------------------------------------------------
    // Output register + FIFO drain logic
    //
    // Fast path (no backpressure, FIFO empty):
    //   pred_valid fires → bypass directly to output register (same latency as
    //   the original single-register implementation).
    //
    // Overflow path (output stalled OR FIFO already has entries ahead):
    //   pred_valid fires → push to FIFO tail.
    //
    // Drain path:
    //   When output is consumed and FIFO is non-empty → pop FIFO head to output.
    // -------------------------------------------------------------------------
    integer j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axis_tvalid <= 1'b0;
            m_axis_tdata  <= 48'd0;
            wr_ptr        <= {(FIFO_AW+1){1'b0}};
            rd_ptr        <= {(FIFO_AW+1){1'b0}};
            for (j = 0; j < FIFO_DEPTH; j = j + 1)
                fifo_mem[j] <= 48'd0;
        end else begin
            // ----------------------------------------------------------------
            // Step 1: Update output register
            // ----------------------------------------------------------------
            if (m_axis_tvalid && m_axis_tready) begin
                // Current beat consumed — load next from FIFO, or bypass, or idle
                if (!fifo_empty) begin
                    m_axis_tdata  <= fifo_mem[rd_ptr[FIFO_AW-1:0]];
                    m_axis_tvalid <= 1'b1;
                    rd_ptr        <= rd_ptr + 1'b1;
                end else if (pred_valid) begin
                    // FIFO empty, new prediction: bypass directly to output
                    m_axis_tdata  <= pred_word;
                    m_axis_tvalid <= 1'b1;
                    // (no FIFO push — handled in step 2 guard below)
                end else begin
                    m_axis_tvalid <= 1'b0;
                end
            end else if (!m_axis_tvalid && pred_valid) begin
                // Output was idle — bypass directly
                m_axis_tdata  <= pred_word;
                m_axis_tvalid <= 1'b1;
            end

            // ----------------------------------------------------------------
            // Step 2: Push to FIFO when output register is occupied and either
            //   (a) output is stalled (tready=0), or
            //   (b) output is being consumed but FIFO is non-empty (FIFO head
            //       will load into output; new prediction queues at FIFO tail).
            // Bypassed cases (no FIFO push): output idle, or output consumed
            //   with FIFO empty (direct bypass in step 1).
            // ----------------------------------------------------------------
            if (pred_valid) begin
                if ((m_axis_tvalid && !m_axis_tready) ||
                    (m_axis_tvalid &&  m_axis_tready && !fifo_empty)) begin
                    if (!fifo_full) begin
                        fifo_mem[wr_ptr[FIFO_AW-1:0]] <= pred_word;
                        wr_ptr <= wr_ptr + 1'b1;
                    end
                    // else: FIFO full — newest prediction dropped (see assertion)
                end
            end
        end
    end

`ifdef SIMULATION
    // -------------------------------------------------------------------------
    // Simulation assertions  (synthesised away in implementation)
    // -------------------------------------------------------------------------

    // 1. AXI4-S rule: TVALID must not deassert until TREADY is seen
    reg tvalid_prev;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) tvalid_prev <= 1'b0;
        else        tvalid_prev <= m_axis_tvalid;
    end
    always @(posedge clk) begin
        if (rst_n && tvalid_prev && !m_axis_tvalid && !m_axis_tready) begin
            $display("AXI4S PROTOCOL ERROR: TVALID deasserted without TREADY at time %0t", $time);
            $finish;
        end
    end

    // 2. FIFO overflow warning (drop event — not a protocol error, but noteworthy)
    always @(posedge clk) begin
        if (rst_n && pred_valid &&
            (m_axis_tvalid && !m_axis_tready) &&
            fifo_full) begin
            $display("AXI4S PRED WRAPPER WARNING: FIFO full, prediction dropped at time %0t", $time);
        end
    end
`endif

endmodule
