// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of BoogieWings_MiSTer.

    BoogieWings_MiSTer is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    BoogieWings_MiSTer is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with BoogieWings_MiSTer.  If not, see <http://www.gnu.org/licenses/>.

    Author: Umberto Parisi (rmonic79)
    Version: 1.0
    Date: 2026

*/

// pause_text.sv — BRAM-based text renderer for the pause overlay.
//
// Generates a character layer (8x8 font) over a rectangular screen area
// (W_CHARS x H_CHARS characters), reading from a BRAM initialised from a file (.mem).
//
// Modes:
//   SCROLL_EN=0: static text, the BRAM holds exactly W_CHARS×H_CHARS ASCII bytes.
//   SCROLL_EN=1: text scrolls vertically bottom→top, the BRAM holds
//                W_CHARS × MSG_ROWS ASCII characters (MSG_ROWS may be > H_CHARS).
//                Speed: 1 pixel every SCROLL_PERIOD frames.
//
// Output: pixel_on = 1 when the character pixel at (render_x, render_y) is lit.
//         The caller mixes it with an external palette.
//
// BRAM cost:
//   font_rom: 1024 bytes = 1 M10K (external, shared by all instances)
//   msg_rom:  W_CHARS × MSG_ROWS bytes (1 M10K if < ~4 KB)

module pause_text #(
	parameter        W_CHARS      = 41,           // area width in characters (8 px each)
	parameter        H_CHARS      = 18,           // visible area height in characters
	parameter        MSG_ROWS     = 18,           // total rows in the buffer (>= H_CHARS)
	parameter [9:0]  ORIGIN_X     = 10'd16,       // pixel X of the top-left corner
	parameter [8:0]  ORIGIN_Y     = 9'd40,        // pixel Y of the top-left corner
	parameter        SCROLL_EN    = 0,            // 0=static, 1=vertical scroll
	parameter        SCROLL_PERIOD = 3,           // 1 pixel every N frames (if SCROLL_EN=1)
	parameter        FONT_FILE    = "logo/font_darius.hex",
	parameter        MSG_FILE     = "logo/links.mem"
) (
	input  wire        clk,
	input  wire        active,        // overlay active (pause & ~clean)
	input  wire        vblank_pulse,  // 1 cycle per frame, scroll tick

	input  wire [9:0]  render_x,
	input  wire [8:0]  render_y,

	// Shared (external) font ROM: this module drives the address and receives the row.
	output wire [9:0]  font_addr_o,   // {ascii, row} to the shared font ROM
	input  wire [7:0]  font_row_i,    // font row (8 px) from the shared ROM

	output reg         pixel_on,      // 1 = lit character pixel
	output reg  [1:0]  pixel_tier     // colour tier (0..3) of the current pixel
);

localparam W_PX = W_CHARS * 8;
localparam H_PX = H_CHARS * 8;

// =====================================================================
// Scroll counter: vertical pixel offset (0..MSG_ROWS*8-1, continuous wrap)
// =====================================================================
localparam MSG_PX = MSG_ROWS * 8;
localparam SCRPOSW = $clog2(MSG_PX + 1);

reg [SCRPOSW-1:0] scrpos;
reg [3:0]         scr_div;

always @(posedge clk) begin
	if (!active) begin
		scrpos  <= '0;
		scr_div <= 4'd0;
	end else if (SCROLL_EN && vblank_pulse) begin
		if (scr_div == SCROLL_PERIOD - 1) begin
			scr_div <= 4'd0;
			if (scrpos == MSG_PX - 1)
				scrpos <= '0;
			else
				scrpos <= scrpos + 1'b1;
		end else begin
			scr_div <= scr_div + 4'd1;
		end
	end
end

// =====================================================================
// Read one pixel ahead on render_x to align the BRAM pipeline
// =====================================================================
wire [9:0] x_ahead = render_x + 10'd1;

// In-bounds check (on the look-ahead pixel)
wire in_area_ahead = active &&
	(x_ahead   >= ORIGIN_X) && (x_ahead   < ORIGIN_X + W_PX) &&
	(render_y  >= ORIGIN_Y) && (render_y  < ORIGIN_Y + H_PX);

// Pixel coordinates relative to the area (0..W_PX-1, 0..H_PX-1)
wire [9:0] dx = x_ahead - ORIGIN_X;
wire [9:0] dy_rel = {1'b0, render_y} - {1'b0, ORIGIN_Y};

// Effective Y (with scroll wrap)
// SCROLL_EN=1: dy_eff = (dy_rel + scrpos) mod MSG_PX
// SCROLL_EN=0: dy_eff = dy_rel (always inside the H_CHARS×8 buffer)
wire [SCRPOSW-1:0] dy_sum   = dy_rel[SCRPOSW-1:0] + scrpos;
wire [SCRPOSW-1:0] dy_wrap  = (dy_sum >= MSG_PX) ? (dy_sum - MSG_PX) : dy_sum;
wire [SCRPOSW-1:0] dy_eff   = SCROLL_EN ? dy_wrap : dy_rel[SCRPOSW-1:0];

// Char column / pixel column (within char)
wire [$clog2(W_CHARS+1)-1:0] char_col = dx[$clog2(W_CHARS*8+1)-1:3];
wire [2:0]                    pix_col = dx[2:0];

// Char row / pixel row (within char)
wire [$clog2(MSG_ROWS+1)-1:0] char_row = dy_eff[SCRPOSW-1:3];
wire [2:0]                    pix_row = dy_eff[2:0];

// =====================================================================
// MSG ROM: W_CHARS × MSG_ROWS words, 9 bits per character (2-bit tier + 7-bit ASCII)
// =====================================================================
localparam MSG_DEPTH = W_CHARS * MSG_ROWS;
localparam MSG_AW    = $clog2(MSG_DEPTH);

(* ramstyle = "M10K" *) reg [8:0] msg_rom [0:MSG_DEPTH-1];
initial $readmemh(MSG_FILE, msg_rom);

wire [MSG_AW-1:0] msg_addr = char_row * W_CHARS + char_col;
reg  [8:0] msg_q;
always @(posedge clk) msg_q <= msg_rom[msg_addr];

wire [1:0] msg_tier  = msg_q[8:7];
wire [6:0] msg_ascii = msg_q[6:0];

// =====================================================================
// SHARED FONT ROM (external, 1 M10K for the whole pause overlay).
// This module drives font_addr_o and receives font_row_i (registered by the ROM).
// =====================================================================
// pix_row is delayed by 1 cycle to line up with msg_q
reg [2:0] pix_row_d;
reg [2:0] pix_col_d;
reg       in_area_d;
always @(posedge clk) begin
	pix_row_d <= pix_row;
	pix_col_d <= pix_col;
	in_area_d <= in_area_ahead;
end

assign font_addr_o = {msg_ascii, pix_row_d};
wire [7:0] font_row = font_row_i;   // font row already registered by the shared ROM
reg  [1:0] tier_d;
always @(posedge clk) begin
	tier_d   <= msg_tier;
end

// pix_col is delayed by 2 cycles in total (msg_q→font_addr→font_row)
reg [2:0] pix_col_dd;
reg       in_area_dd;
reg [1:0] tier_dd;
always @(posedge clk) begin
	pix_col_dd <= pix_col_d;
	in_area_dd <= in_area_d;
	tier_dd    <= tier_d;
end

// Output: bit pix_col_dd of the current font_row, gated by in_area
always @(posedge clk) begin
	pixel_on   <= in_area_dd && font_row[7 - pix_col_dd];
	pixel_tier <= tier_dd;
end

endmodule
