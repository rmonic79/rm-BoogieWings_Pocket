/*  This file is part of BoogieWings_MiSTer.
    GPL-3.
    Author: Umberto Parisi (rmonic79)
*/

//============================================================================
//  ss_ddr_gate — Savestate DDR gate, TRANSPARENT by construction.
//
//  Generic cross-core module.
//  Multiplexes the DDRAM_* signals between the GAME MASTER (arbiter/ddram_4port) and
//  the SAVESTATE MASTER (memory_stream), granting the bus to the SS only at a
//  clean boundary and giving it back without losing transactions.
//
//  === TRANSPARENCY RULE (invariant, do NOT violate) ===
//  With SS inactive (ss_busy=0) the module is INERT: hold/grant stay 0 and the MUX
//  always gives the bus to the game -> behaviour bit-identical to a core without it.
//  The FALL of hold/grant depends ONLY on signals INTERNAL to the SS
//  (ss_busy, ss_tx_inflight), NEVER on the game's DDR traffic. Tying the fall
//  to the game traffic (bus-quiet) starves the DDR clients (e.g. OKI) because during
//  normal play the bus is never quiet -> grant stays latched (broken sound effects).
//
//  ss_bus_quiet (game traffic) is allowed ONLY on the RISE of the grant: it drains
//  the arbiter BEFORE taking the bus (latch-on-drain), immune to the cold-boot
//  deadlock (under hold the arbiter does not clear pending rd_req, so waiting
//  for rd_ack==rd_req would hang the restore at the first cache miss).
//
//  NB: same clock domain as DDRAM (DDRAM_CLK = clk). No CDC.
//============================================================================

`timescale 1ns / 1ps

module ss_ddr_gate #(
	parameter integer AW       = 29,  // DDRAM_ADDR width
	parameter integer DRAIN_TH = 3    // idle bus cycles required before the grant
) (
	input  wire           clk,
	input  wire           reset,

	// Savestate status (signals INTERNAL to the SS — the only allowed triggers)
	input  wire           ss_busy,        // memory_stream busy (save_state_data.busy)
	input  wire           ss_tx_inflight, // SS transaction in flight (ss_ddr.read | ss_ddr.write)

	// GAME master (arbiter/ddram_4port)
	input  wire [7:0]     game_burstcnt,
	input  wire [AW-1:0]  game_addr,
	input  wire           game_rd,
	input  wire [63:0]    game_din,
	input  wire [7:0]     game_be,
	input  wire           game_we,

	// SAVESTATE master (memory_stream via ss_ddr)
	input  wire [7:0]     ss_burstcnt,
	input  wire [AW-1:0]  ss_addr,
	input  wire           ss_rd,
	input  wire [63:0]    ss_din,
	input  wire [7:0]     ss_be,
	input  wire           ss_we,

	// Physical DDR bus status (for draining and clean release)
	input  wire           DDRAM_BUSY,
	input  wire           DDRAM_DOUT_READY,  // read beat from the controller (in-flight burst count)

	// Outputs to the DDR3 controller (mux'd)
	output wire [7:0]     DDRAM_BURSTCNT,
	output wire [AW-1:0]  DDRAM_ADDR,
	output wire           DDRAM_RD,
	output wire [63:0]    DDRAM_DIN,
	output wire [7:0]     DDRAM_BE,
	output wire           DDRAM_WE,

	// Control to the arbiter / memory_stream
	output reg            ss_hold,        // 1: stops the arbiter from issuing
	output reg            ss_ddr_grant    // 1: the MUX routes DDRAM_* to the SS
);

// Pending game read beats: a DDR read is a 1-clk STROBE, but the response beats arrive
// after the controller latency (tens of clks) with RD=WE=0 and BUSY often 0. A quiet test
// on ~RD&~WE&~BUSY alone would count the bus as idle WITH a burst in flight: the grant
// would rise mid-transaction and memory_stream would capture the GAME's beats as stream
// header/data (corrupted restore). So the expected beats are counted: +burstcnt on an
// accepted read (pre-grant = game read), -1 on each DDRAM_DOUT_READY while pending>0.
// Quiet only at zero.
reg [8:0] game_beats_pending = 9'd0;
always @(posedge clk) begin
	if (reset) begin
		game_beats_pending <= 9'd0;
	end else begin
		case ({(DDRAM_RD & ~DDRAM_BUSY & ~ss_ddr_grant), (DDRAM_DOUT_READY & (game_beats_pending != 9'd0))})
			2'b10:   game_beats_pending <= game_beats_pending + {1'b0, DDRAM_BURSTCNT};
			2'b01:   game_beats_pending <= game_beats_pending - 9'd1;
			2'b11:   game_beats_pending <= game_beats_pending + {1'b0, DDRAM_BURSTCNT} - 9'd1;
			default: ;
		endcase
	end
end

// "bus quiet" = NO physical DDR transaction in flight, PENDING BEATS INCLUDED. Read
// after the MUX: with grant=0 DDRAM_RD/WE are game_* (the arbiter) -> game transactions.
wire ss_bus_quiet = ~DDRAM_RD & ~DDRAM_WE & ~DDRAM_BUSY & (game_beats_pending == 9'd0);

reg [3:0] ss_drain_cnt = 4'd0;

always @(posedge clk) begin
	if (reset) begin
		ss_hold      <= 1'b0;
		ss_ddr_grant <= 1'b0;
		ss_drain_cnt <= 4'd0;
	end else begin
		// HOLD: high for the whole SS request (stops the arbiter from issuing; client requests
		// stay pending, NOT frozen halfway). Falls as soon as the SS is no longer active and
		// has no raw transactions in flight. Does NOT depend on the game's DDR traffic.
		if (ss_busy) ss_hold <= 1'b1;
		else if (~ss_tx_inflight) ss_hold <= 1'b0;

		// DRAIN: with hold high and the SS not yet granted, count the idle bus cycles. If a
		// transaction starts again (the arbiter was finishing a burst issued before the hold),
		// the count restarts. Saturates at the threshold (no wrap). Here ss_bus_quiet is
		// allowed: it drains the game arbiter.
		if (ss_hold & ~ss_ddr_grant & ss_busy)
			ss_drain_cnt <= ss_bus_quiet ? (ss_drain_cnt == DRAIN_TH[3:0] ? DRAIN_TH[3:0] : ss_drain_cnt + 4'd1) : 4'd0;
		else
			ss_drain_cnt <= 4'd0;

		// GRANT (LATCH): rises when the game bus is stably drained, then STAYS high until the end
		// of the SS. Falls ONLY when the SS is no longer active and has no raw transactions in
		// flight — it does NOT depend on ss_bus_quiet (never true during normal play -> starved
		// DDR clients). With SS inactive: ss_busy=0 & ss_tx_inflight=0 -> grant falls and stays 0
		// -> MUX always to the game.
		if (ss_hold & ss_busy & (ss_drain_cnt >= DRAIN_TH[3:0])) ss_ddr_grant <= 1'b1;
		else if (~ss_busy & ~ss_tx_inflight) ss_ddr_grant <= 1'b0;
	end
end

assign DDRAM_BURSTCNT = ss_ddr_grant ? ss_burstcnt : game_burstcnt;
assign DDRAM_ADDR     = ss_ddr_grant ? ss_addr     : game_addr;
assign DDRAM_RD       = ss_ddr_grant ? ss_rd       : game_rd;
assign DDRAM_DIN      = ss_ddr_grant ? ss_din      : game_din;
assign DDRAM_BE       = ss_ddr_grant ? ss_be       : game_be;
assign DDRAM_WE       = ss_ddr_grant ? ss_we       : game_we;

endmodule
