`timescale 1ns/1ps
`default_nettype none

// Simple AER RX shell: captures REQ and emits one-cycle valid with address/pol
//
// PROTOCOL ASSUMPTIONS (must be documented for external evaluation):
// - Level-sensitive request: aer_req is sampled on rising clock edge
// - One-cycle acknowledge: aer_ack asserts for exactly one cycle when aer_req is high
// - Address stability: source must hold aer_x/aer_y/aer_pol stable while aer_req=1
// - No handshake wait: this module does NOT wait for aer_req to deassert before
//   accepting a new request. The source must deassert aer_req within one cycle
//   of seeing aer_ack, or multiple events will be generated.
//
// This is a SIMPLIFIED protocol suitable for:
// - Internal simulation/testbenches
// - Integration with frame-based AER where each frame provides one pulse per event
//
// For true 4-phase handshake AER, this module would need modification to:
// - Hold aer_ack until aer_req deasserts
// - Wait for aer_req reassertion before next transfer
//
module aer_rx #(
    parameter XW=10, YW=10
)(
    input  wire          clk, rst,
    input  wire          aer_req,
    output wire          aer_ack,
    input  wire [XW-1:0] aer_x,
    input  wire [YW-1:0] aer_y,
    input  wire          aer_pol,
    output wire          ev_valid,
    output wire [XW-1:0] ev_x,
    output wire [YW-1:0] ev_y,
    output wire          ev_pol
);
    // Combinational ack, ev_valid, and event data: all respond same cycle as req
    // This matches the documented behavior that N cycles with req=1 yields N events
    // with correct data on each cycle
    assign aer_ack = aer_req && !rst;
    assign ev_valid = aer_req && !rst;

    // Event data is passed through combinationally when valid, else zero
    assign ev_x = (aer_req && !rst) ? aer_x : {XW{1'b0}};
    assign ev_y = (aer_req && !rst) ? aer_y : {YW{1'b0}};
    assign ev_pol = (aer_req && !rst) ? aer_pol : 1'b0;
endmodule

`default_nettype wire
