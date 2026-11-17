// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) Umberto Parisi (rmonic79).
//
// pocket_ddram — takes emu's DDRAM_* bus (same Avalon-MM semantics as on
// MiSTer: 64-bit word, burst, waitrequest = BUSY, readdatavalid = DOUT_READY)
// and serves it from the Pocket PSRAMs (pocket_psram port).
//
// Map: up to four DDR address windows (bytes) mapped onto the PSRAM (bytes).
// Window size 2^Wn_LOG2, aligned base; Wn_LOG2 = 0 = disabled.
// Outside the windows: writes are ignored, reads return 0 (with DOUT_READY).
// The read monitor (mon_rd) watches window SS_WIN (the savestate one).
//
// BUSY: MiSTer clients (e.g. memory_stream) look at DOUT_READY ONLY when BUSY
// is low. So BUSY here rises only when a command arrives that cannot be
// accepted at that moment; when idle and while waiting for data it stays low.
//
// Monitor (for Pocket savestates): mon_wr pulses on every beat written to
// address MON_WR_BYTE; mon_rd pulses on every read command in window SS_WIN.

module pocket_ddram #(
	parameter [31:0] W0_DDR   = 32'h30000000,   // DDR base of window 0 (bytes)
	parameter [31:0] W0_PSRAM = 32'h00000000,   // PSRAM base of window 0 (bytes)
	parameter integer W0_LOG2 = 23,             // size of window 0 = 2^W0_LOG2 bytes
	parameter [31:0] W1_DDR   = 32'h3E000000,
	parameter [31:0] W1_PSRAM = 32'h00800000,
	parameter integer W1_LOG2 = 23,
	parameter [31:0] W2_DDR   = 32'h00000000,
	parameter [31:0] W2_PSRAM = 32'h00000000,
	parameter integer W2_LOG2 = 0,
	parameter [31:0] W3_DDR   = 32'h00000000,
	parameter [31:0] W3_PSRAM = 32'h00000000,
	parameter integer W3_LOG2 = 0,
	parameter integer SS_WIN  = 1,
	parameter [31:0] MON_WR_BYTE = 32'h3E000000
)(
	input             clk,

	input      [28:0] ddr_addr,
	input       [7:0] ddr_burstcnt,
	input             ddr_rd,
	input             ddr_we,
	input      [63:0] ddr_din,
	input       [7:0] ddr_be,
	output            ddr_busy,
	output reg [63:0] ddr_dout = 0,
	output reg        ddr_dout_ready = 0,

	output reg        ps_req = 0,
	output reg        ps_we,
	output reg [22:0] ps_addr,
	output reg [31:0] ps_wdata,
	output reg  [3:0] ps_be,
	input             ps_ack,
	input      [31:0] ps_rdata,

	output reg        mon_wr = 0,
	output reg        mon_rd = 0
);

localparam S_IDLE    = 3'd0;
localparam S_RD_LO   = 3'd1;
localparam S_RD_HI   = 3'd2;
localparam S_WR_LO   = 3'd3;
localparam S_WR_HI   = 3'd4;
localparam S_WR_NEXT = 3'd5;   // waiting for the next beat of a write burst

reg  [2:0] state = S_IDLE;
reg  [7:0] cnt;
reg [31:0] cur_byte;          // DDR address (bytes) of the current beat
reg [63:0] wdata;
reg  [7:0] wbe;
reg [31:0] rd_lo;

wire can_accept_cmd  = (state == S_IDLE);
wire can_accept_beat = (state == S_WR_NEXT);
assign ddr_busy = (ddr_rd & ~can_accept_cmd) | (ddr_we & ~(can_accept_cmd | can_accept_beat));

// does the window contain address b?
function in_win(input [31:0] b, input [31:0] base, input integer lg);
	in_win = (lg != 0) && ((b >> lg) == (base >> lg));
endfunction

// DDR (byte) -> PSRAM (32-bit word) mapping, with a valid flag
function [23:0] map_addr(input [31:0] b);
	reg [31:0] p;
	begin
		map_addr = 24'd0;
		if (in_win(b, W0_DDR, W0_LOG2))      begin p = W0_PSRAM + (b - W0_DDR); map_addr = {1'b1, p[24:2]}; end
		else if (in_win(b, W1_DDR, W1_LOG2)) begin p = W1_PSRAM + (b - W1_DDR); map_addr = {1'b1, p[24:2]}; end
		else if (in_win(b, W2_DDR, W2_LOG2)) begin p = W2_PSRAM + (b - W2_DDR); map_addr = {1'b1, p[24:2]}; end
		else if (in_win(b, W3_DDR, W3_LOG2)) begin p = W3_PSRAM + (b - W3_DDR); map_addr = {1'b1, p[24:2]}; end
	end
endfunction

wire [23:0] cur_map = map_addr(cur_byte);
wire        cur_ok  = cur_map[23];
wire [31:0] in_byte = {ddr_addr, 3'b000};
wire        in_w1   = (SS_WIN == 0) ? in_win(in_byte, W0_DDR, W0_LOG2) :
                      (SS_WIN == 1) ? in_win(in_byte, W1_DDR, W1_LOG2) :
                      (SS_WIN == 2) ? in_win(in_byte, W2_DDR, W2_LOG2) :
                                      in_win(in_byte, W3_DDR, W3_LOG2);

always @(posedge clk) begin
	ddr_dout_ready <= 0;
	mon_wr <= 0;
	mon_rd <= 0;

	case (state)
		S_IDLE: begin
			if (ddr_rd) begin
				cur_byte <= in_byte;
				cnt      <= (ddr_burstcnt == 8'd0) ? 8'd1 : ddr_burstcnt;
				mon_rd   <= in_w1;
				state    <= S_RD_LO;
			end
			else if (ddr_we) begin
				cur_byte <= in_byte;
				cnt      <= (ddr_burstcnt == 8'd0) ? 8'd1 : ddr_burstcnt;
				wdata    <= ddr_din;
				wbe      <= ddr_be;
				mon_wr   <= (in_byte == MON_WR_BYTE);
				state    <= S_WR_LO;
			end
		end

		// ---------------- read: 2 PSRAM words per beat ----------------
		S_RD_LO: begin
			if (!cur_ok) begin
				ddr_dout       <= 64'd0;
				ddr_dout_ready <= 1;
				cnt            <= cnt - 8'd1;
				cur_byte       <= cur_byte + 32'd8;
				if (cnt == 8'd1) state <= S_IDLE;
			end
			else if (!ps_req) begin
				ps_req  <= 1; ps_we <= 0; ps_be <= 4'hF;
				ps_addr <= {cur_map[22:1], 1'b0};
			end
			else if (ps_ack) begin
				ps_req <= 0;
				rd_lo  <= ps_rdata;
				state  <= S_RD_HI;
			end
		end
		S_RD_HI: begin
			if (!ps_req) begin
				ps_req  <= 1; ps_we <= 0; ps_be <= 4'hF;
				ps_addr <= {cur_map[22:1], 1'b1};
			end
			else if (ps_ack) begin
				ps_req         <= 0;
				ddr_dout       <= {ps_rdata, rd_lo};
				ddr_dout_ready <= 1;
				cnt            <= cnt - 8'd1;
				cur_byte       <= cur_byte + 32'd8;
				state          <= (cnt == 8'd1) ? S_IDLE : S_RD_LO;
			end
		end

		// ---------------- write: 2 PSRAM words per beat ----------------
		S_WR_LO: begin
			if (!cur_ok || wbe[3:0] == 4'h0) state <= S_WR_HI;
			else if (!ps_req) begin
				ps_req   <= 1; ps_we <= 1; ps_be <= wbe[3:0];
				ps_addr  <= {cur_map[22:1], 1'b0};
				ps_wdata <= wdata[31:0];
			end
			else if (ps_ack) begin
				ps_req <= 0;
				state  <= S_WR_HI;
			end
		end
		S_WR_HI: begin
			if (!cur_ok || wbe[7:4] == 4'h0 || (ps_req && ps_ack)) begin
				ps_req   <= 0;
				cnt      <= cnt - 8'd1;
				cur_byte <= cur_byte + 32'd8;
				state    <= (cnt == 8'd1) ? S_IDLE : S_WR_NEXT;
			end
			else if (!ps_req) begin
				ps_req   <= 1; ps_we <= 1; ps_be <= wbe[7:4];
				ps_addr  <= {cur_map[22:1], 1'b1};
				ps_wdata <= wdata[63:32];
			end
		end
		S_WR_NEXT: begin
			if (ddr_we) begin
				wdata  <= ddr_din;
				wbe    <= ddr_be;
				mon_wr <= (cur_byte == MON_WR_BYTE);
				state  <= S_WR_LO;
			end
		end

		default: state <= S_IDLE;
	endcase
end

endmodule
