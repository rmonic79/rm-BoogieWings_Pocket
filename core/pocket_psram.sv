// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) Umberto Parisi (rmonic79).
//
// pocket_psram — asynchronous controller for the two Pocket PSRAMs (cram0,
// cram1) used IN PARALLEL as a single 32-bit memory:
//   cram0 = bits [15:0], cram1 = bits [31:16], same address on both.
// 32-bit word address: addr[22] = die (ce0/ce1), addr[21:0] = word within
// the die -> 8M words x 32 bits = 32 MB.
//
// Timing (asynchronous mode, AS1C8M16PL-70, multiplexed ADV/DQ), derived from
// Adam Gastineau's controller (analogue-pocket-utils, MIT) and recalculated for
// the clock of this module (parameter T_ACC):
//   cycle 0      : CE low, ADV low, address on DQ (+ WE low for a write)
//   cycle 1      : ADV high (address latched, tAVS >= 5 ns)
//   cycle 2      : DQ released (tAVH >= 2 ns)
//   cycle 3      : write -> data on DQ ; read -> OE low
//   cycle T_ACC  : read -> sample DQ ; write -> WE high. Then CE high.
// T_ACC = ceil(70 ns / period) + 1 cycle of margin for the I/O delays.
// At 80 MHz (12.5 ns): ceil(5.6) + 1 = 7 -> sampling 87.5 ns after ADV low
// (spec 70 ns), WE low for 87.5 ns (spec tWP 45 ns), data on DQ 50 ns before
// the WE edge (spec tDW 20 ns). Access period 8 cycles.
// For another clock: T_ACC = ceil(70 / period_ns) + 1.
//
// Four ports (0 = core DDR, 3 = core auxiliary port, 1 = Pocket bridge,
// 2 = .rom read-back). Ports 0 and 3 TAKE TURNS: if both request, the one not
// served last goes first, so each waits at most one access of the other.
// 1 and 2 come after (they are needed only when the core does not use the
// PSRAM: loading, savestate). Per-port protocol: req high and data stable
// until ack arrives (1-cycle pulse, rdata valid in the same cycle). One
// transaction at a time.
//
// Word 0x3FFFFF of each die (the last one) NEVER goes to the PSRAM: a
// sequence of accesses to that address can open the PSRAM configuration
// registers (Analogue documentation, "Software Access"). As Analogue
// suggests, those two words live in FPGA registers (lastw[die]): the same
// memory as seen from outside, with the same byte enables.

module pocket_psram #(
	parameter integer T_ACC = 7      // cycles from ADV low to sampling (see above)
)(
	input             clk,

	input             p0_req,
	input             p0_we,
	input      [22:0] p0_addr,
	input      [31:0] p0_wdata,
	input       [3:0] p0_be,
	output reg        p0_ack = 0,

	input             p1_req,
	input             p1_we,
	input      [22:0] p1_addr,
	input      [31:0] p1_wdata,
	input       [3:0] p1_be,
	output reg        p1_ack = 0,

	input             p2_req,
	input             p2_we,
	input      [22:0] p2_addr,
	input      [31:0] p2_wdata,
	input       [3:0] p2_be,
	output reg        p2_ack = 0,

	input             p3_req,
	input             p3_we,
	input      [22:0] p3_addr,
	input      [31:0] p3_wdata,
	input       [3:0] p3_be,
	output reg        p3_ack = 0,

	output reg [31:0] rdata,     // valid in the ack cycle of the served port

	output reg [21:16] cram0_a = 0,
	inout      [15:0] cram0_dq,
	output            cram0_clk,
	output reg        cram0_adv_n = 1,
	output            cram0_cre,
	output reg        cram0_ce0_n = 1,
	output reg        cram0_ce1_n = 1,
	output reg        cram0_oe_n = 1,
	output reg        cram0_we_n = 1,
	output reg        cram0_ub_n = 1,
	output reg        cram0_lb_n = 1,

	output reg [21:16] cram1_a = 0,
	inout      [15:0] cram1_dq,
	output            cram1_clk,
	output reg        cram1_adv_n = 1,
	output            cram1_cre,
	output reg        cram1_ce0_n = 1,
	output reg        cram1_ce1_n = 1,
	output reg        cram1_oe_n = 1,
	output reg        cram1_we_n = 1,
	output reg        cram1_ub_n = 1,
	output reg        cram1_lb_n = 1
);

assign cram0_clk = 1'b0;
assign cram1_clk = 1'b0;
assign cram0_cre = 1'b0;
assign cram1_cre = 1'b0;

reg [15:0] dq0_out, dq1_out;
reg        dq_oe = 0;
assign cram0_dq = dq_oe ? dq0_out : 16'hZZZZ;
assign cram1_dq = dq_oe ? dq1_out : 16'hZZZZ;

reg  [4:0] cyc = 0;
reg        busy = 0;
reg        cur_we;
reg  [1:0] cur_port;
reg [31:0] cur_wdata;
reg        cur_skip;
reg  [3:0] cur_be;
reg        cur_die;
reg [31:0] lastw [0:1];           // last word of the two dies
reg        last3 = 0;             // 1 = the last port served between 0 and 3 was 3
wire       pick0 = p0_req && !p0_ack && (!(p3_req && !p3_ack) || last3);
wire       pick3 = p3_req && !p3_ack && !pick0;
initial begin lastw[0] = 32'd0; lastw[1] = 32'd0; end

wire p0_bad = &p0_addr[21:0];
wire p1_bad = &p1_addr[21:0];
wire p2_bad = &p2_addr[21:0];
wire p3_bad = &p3_addr[21:0];

always @(posedge clk) begin
	p0_ack <= 0;
	p1_ack <= 0;
	p2_ack <= 0;
	p3_ack <= 0;

	if (!busy) begin
		cram0_ce0_n <= 1; cram0_ce1_n <= 1; cram1_ce0_n <= 1; cram1_ce1_n <= 1;
		cram0_oe_n  <= 1; cram1_oe_n  <= 1;
		cram0_we_n  <= 1; cram1_we_n  <= 1;
		cram0_adv_n <= 1; cram1_adv_n <= 1;
		cram0_ub_n  <= 1; cram0_lb_n  <= 1; cram1_ub_n <= 1; cram1_lb_n <= 1;
		dq_oe <= 0;

		// requests already served in this cycle (ack) must not be taken again:
		// the requester drops req only from the cycle after the ack.
		if (pick0) begin
			last3 <= 0;
			busy <= 1; cyc <= 0; cur_port <= 2'd0; cur_we <= p0_we; cur_skip <= p0_bad;
			cur_wdata <= p0_wdata; cur_be <= p0_be; cur_die <= p0_addr[22];
			if (!p0_bad) begin
				{cram0_ce1_n, cram0_ce0_n} <= p0_addr[22] ? 2'b01 : 2'b10;
				{cram1_ce1_n, cram1_ce0_n} <= p0_addr[22] ? 2'b01 : 2'b10;
				cram0_a <= p0_addr[21:16]; cram1_a <= p0_addr[21:16];
				dq0_out <= p0_addr[15:0];  dq1_out <= p0_addr[15:0];
				dq_oe <= 1;
				cram0_adv_n <= 0; cram1_adv_n <= 0;
				cram0_we_n <= ~p0_we; cram1_we_n <= ~p0_we;
				{cram0_ub_n, cram0_lb_n} <= p0_we ? ~p0_be[1:0] : 2'b00;
				{cram1_ub_n, cram1_lb_n} <= p0_we ? ~p0_be[3:2] : 2'b00;
			end
		end
		else if (pick3) begin
			last3 <= 1;
			busy <= 1; cyc <= 0; cur_port <= 2'd3; cur_we <= p3_we; cur_skip <= p3_bad;
			cur_wdata <= p3_wdata; cur_be <= p3_be; cur_die <= p3_addr[22];
			if (!p3_bad) begin
				{cram0_ce1_n, cram0_ce0_n} <= p3_addr[22] ? 2'b01 : 2'b10;
				{cram1_ce1_n, cram1_ce0_n} <= p3_addr[22] ? 2'b01 : 2'b10;
				cram0_a <= p3_addr[21:16]; cram1_a <= p3_addr[21:16];
				dq0_out <= p3_addr[15:0];  dq1_out <= p3_addr[15:0];
				dq_oe <= 1;
				cram0_adv_n <= 0; cram1_adv_n <= 0;
				cram0_we_n <= ~p3_we; cram1_we_n <= ~p3_we;
				{cram0_ub_n, cram0_lb_n} <= p3_we ? ~p3_be[1:0] : 2'b00;
				{cram1_ub_n, cram1_lb_n} <= p3_we ? ~p3_be[3:2] : 2'b00;
			end
		end
		else if (p1_req && !p1_ack) begin
			busy <= 1; cyc <= 0; cur_port <= 2'd1; cur_we <= p1_we; cur_skip <= p1_bad;
			cur_wdata <= p1_wdata; cur_be <= p1_be; cur_die <= p1_addr[22];
			if (!p1_bad) begin
				{cram0_ce1_n, cram0_ce0_n} <= p1_addr[22] ? 2'b01 : 2'b10;
				{cram1_ce1_n, cram1_ce0_n} <= p1_addr[22] ? 2'b01 : 2'b10;
				cram0_a <= p1_addr[21:16]; cram1_a <= p1_addr[21:16];
				dq0_out <= p1_addr[15:0];  dq1_out <= p1_addr[15:0];
				dq_oe <= 1;
				cram0_adv_n <= 0; cram1_adv_n <= 0;
				cram0_we_n <= ~p1_we; cram1_we_n <= ~p1_we;
				{cram0_ub_n, cram0_lb_n} <= p1_we ? ~p1_be[1:0] : 2'b00;
				{cram1_ub_n, cram1_lb_n} <= p1_we ? ~p1_be[3:2] : 2'b00;
			end
		end
		else if (p2_req && !p2_ack) begin
			busy <= 1; cyc <= 0; cur_port <= 2'd2; cur_we <= p2_we; cur_skip <= p2_bad;
			cur_wdata <= p2_wdata; cur_be <= p2_be; cur_die <= p2_addr[22];
			if (!p2_bad) begin
				{cram0_ce1_n, cram0_ce0_n} <= p2_addr[22] ? 2'b01 : 2'b10;
				{cram1_ce1_n, cram1_ce0_n} <= p2_addr[22] ? 2'b01 : 2'b10;
				cram0_a <= p2_addr[21:16]; cram1_a <= p2_addr[21:16];
				dq0_out <= p2_addr[15:0];  dq1_out <= p2_addr[15:0];
				dq_oe <= 1;
				cram0_adv_n <= 0; cram1_adv_n <= 0;
				cram0_we_n <= ~p2_we; cram1_we_n <= ~p2_we;
				{cram0_ub_n, cram0_lb_n} <= p2_we ? ~p2_be[1:0] : 2'b00;
				{cram1_ub_n, cram1_lb_n} <= p2_we ? ~p2_be[3:2] : 2'b00;
			end
		end
	end
	else begin
		cyc <= cyc + 5'd1;

		// cyc is 0 in the first cycle after the access is issued (ADV low for 1 cycle)
		if (cyc == 5'd0) begin
			cram0_adv_n <= 1; cram1_adv_n <= 1;
		end
		if (cyc == 5'd1) begin
			dq_oe <= 0;
		end
		if (cyc == 5'd2) begin
			if (cur_we) begin
				dq0_out <= cur_wdata[15:0];
				dq1_out <= cur_wdata[31:16];
				dq_oe   <= ~cur_skip;
			end
			else begin
				cram0_oe_n <= cur_skip;
				cram1_oe_n <= cur_skip;
			end
		end
		if (cyc == T_ACC[4:0] - 5'd1) begin
			busy <= 0;
			rdata <= cur_skip ? lastw[cur_die] : {cram1_dq, cram0_dq};
			if (cur_skip && cur_we) begin
				if (cur_be[0]) lastw[cur_die][7:0]   <= cur_wdata[7:0];
				if (cur_be[1]) lastw[cur_die][15:8]  <= cur_wdata[15:8];
				if (cur_be[2]) lastw[cur_die][23:16] <= cur_wdata[23:16];
				if (cur_be[3]) lastw[cur_die][31:24] <= cur_wdata[31:24];
			end
			cram0_ce0_n <= 1; cram0_ce1_n <= 1; cram1_ce0_n <= 1; cram1_ce1_n <= 1;
			cram0_oe_n  <= 1; cram1_oe_n  <= 1;
			cram0_we_n  <= 1; cram1_we_n  <= 1;
			cram0_ub_n  <= 1; cram0_lb_n  <= 1; cram1_ub_n <= 1; cram1_lb_n <= 1;
			dq_oe <= 0;
			case (cur_port)
				2'd0: p0_ack <= 1;
				2'd1: p1_ack <= 1;
				2'd2: p2_ack <= 1;
				default: p3_ack <= 1;
			endcase
		end
	end
end

endmodule
