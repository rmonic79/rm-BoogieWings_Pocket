// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) Umberto Parisi (rmonic79).
//
// pocket_af_osd -- on-screen autofire indicator.
//
// After each setting (Select + button, pocket_autofire) it shows for FRAMES
// core frames (120 = 2 s) a black box of 29x9 core pixels:
//   columns 1-5    button letter, 5x7: A B X Y L R
//   columns 7-9    a small 2 or 3, 3x5, for L2 R2 / L3 R3
//   columns 11-27  the rate: 1, 2, 3 filled 5x5 squares = 10, 15, 30 shots/s;
//                  3 empty squares = off
// Player 1 at the top left, player 2 at the top right, M pixels from the edges
// of the screen as the player sees it.
//
// Rotation: it is done by the Pocket scaler (video.json slot), so the box must be
// drawn into the core image already rotated the opposite way. QT, 2 bits per slot
// (slot i = bits [2i+1:2i]), quarter turns on the screen:
//   0 = none                              screen (u, v) = (x, y)
//   1 = counter-clockwise (rotation 270)  screen (u, v) = (y, W-1-x)
//   2 = 180 (rotation 180, mirror 3)      screen (u, v) = (W-1-x, H-1-y)
//   3 = clockwise (rotation 90)           screen (u, v) = (H-1-y, x)
// Case 1 matches MiSTer's screen_rotate with rotate_ccw (pixel (x, y) goes to
// row W-1-x, column y of the framebuffer): TATE upright both on MiSTer and on
// the Pocket. The QT values come from the pocket.json slots (macro
// POCKET_SLOT_QT in the project .qsf).
//
// Timing: everything advances with ce_pix (a ce_pix on every clock works too).
// The decision for each pixel is in a register prepared on the previous ce_pix:
// on the way to the RGB there is only a multiplexer.
//   a1/a2: box coordinate along the row, for the next pixel;
//   b1/b2: box coordinate of the row, changes at the end of the row.
// Outside the box the coordinates go out of range (negative = large).
// A change of slot, button or rate in the middle of a frame only corrupts that frame.

module pocket_af_osd #(
	parameter integer W      = 256,     // active pixels per line (video.json width)
	parameter integer H      = 224,     // active lines (video.json height)
	parameter integer QT     = 0,
	parameter integer VS_POL = 1,       // 1 = VSync active high
	parameter integer FRAMES = 120
)(
	input            clk,               // CLK_VIDEO
	input            ce_pix,
	input            de,
	input            vs,
	input      [2:0] slot,              // scaler slot (quasi-static, other clock domain)
	input      [7:0] r_in, g_in, b_in,
	output     [7:0] r_out, g_out, b_out,

	// settings from the two pocket_autofire instances (clk_74a): toggle + stable data
	input            ev1_tog,
	input      [3:0] ev1_key,           // 0 A, 1 B, 2 X, 3 Y, 4 L1, 5 R1, 6 L2, 7 R2, 8 L3, 9 R3
	input      [1:0] ev1_lvl,           // 0 off, 1 = 10/s, 2 = 15/s, 3 = 30/s
	input            ev2_tog,
	input      [3:0] ev2_key,
	input      [1:0] ev2_lvl
);

localparam integer BW = 29, BH = 9, M = 2;
localparam integer U2E = W - M - BW;   // box column of player 2, screen W wide
localparam integer U2O = H - M - BW;   // same with the screen rotated, H wide
localparam [15:0]  QTV = QT;

// ---- slot -> quarter turns -> counter start values and directions (quasi-static)
reg  [2:0] slot_s1 = 0, slot_s2 = 0;
reg  [1:0] q = 0;
reg        sa_n = 0, sb_n = 0;          // counter along the row / counter of the row going down
reg [10:0] a0_1 = 0, a0_2 = 0, b0_1 = 0, b0_2 = 0;

always @(posedge clk) begin
	slot_s1 <= slot;
	slot_s2 <= slot_s1;
	q       <= QTV[{slot_s2, 1'b0} +: 2];
	sa_n    <= (q == 2'd1) || (q == 2'd2);
	sb_n    <= q[1];
	case (q)
	2'd0: begin a0_1 <= -M;    b0_1 <= -M;    a0_2 <= -U2E;    b0_2 <= -M;      end
	2'd1: begin a0_1 <= W-1-M; b0_1 <= -M;    a0_2 <= W-1-M;   b0_2 <= -U2O;    end
	2'd2: begin a0_1 <= W-1-M; b0_1 <= H-1-M; a0_2 <= W-1-U2E; b0_2 <= H-1-M;   end
	2'd3: begin a0_1 <= -M;    b0_1 <= H-1-M; a0_2 <= -M;      b0_2 <= H-1-U2O; end
	endcase
end

// ---- settings: synchronised toggle, data taken on its edge
reg  [2:0] t1 = 0, t2 = 0;
reg  [3:0] k1 = 0, k2 = 0;
reg  [1:0] l1 = 0, l2 = 0;
reg  [7:0] tm1 = 0, tm2 = 0;            // remaining frames of visibility

wire vsa = VS_POL ? vs : ~vs;
reg  de_q = 0, vs_q = 0;
wire frame = ce_pix & vsa & ~vs_q;

always @(posedge clk) begin
	t1 <= {t1[1:0], ev1_tog};
	t2 <= {t2[1:0], ev2_tog};
	if (t1[2] ^ t1[1])  begin k1 <= ev1_key; l1 <= ev1_lvl; tm1 <= FRAMES[7:0]; end
	else if (frame && tm1 != 8'd0) tm1 <= tm1 - 8'd1;
	if (t2[2] ^ t2[1])  begin k2 <= ev2_key; l2 <= ev2_lvl; tm2 <= FRAMES[7:0]; end
	else if (frame && tm2 != 8'd0) tm2 <= tm2 - 8'd1;
end

// ---- box drawing, screen coordinates (u column, v row)
function [4:0] font5(input [2:0] c, input [2:0] r);   // row r of the letter, bit 4 = left
	reg [34:0] g;
	begin
		case (c)
		3'd0:    g = {5'b01110, 5'b10001, 5'b10001, 5'b11111, 5'b10001, 5'b10001, 5'b10001}; // A
		3'd1:    g = {5'b11110, 5'b10001, 5'b10001, 5'b11110, 5'b10001, 5'b10001, 5'b11110}; // B
		3'd2:    g = {5'b10001, 5'b10001, 5'b01010, 5'b00100, 5'b01010, 5'b10001, 5'b10001}; // X
		3'd3:    g = {5'b10001, 5'b10001, 5'b01010, 5'b00100, 5'b00100, 5'b00100, 5'b00100}; // Y
		3'd4:    g = {5'b10000, 5'b10000, 5'b10000, 5'b10000, 5'b10000, 5'b10000, 5'b11111}; // L
		default: g = {5'b11110, 5'b10001, 5'b10001, 5'b11110, 5'b10100, 5'b10010, 5'b10001}; // R
		endcase
		font5 = g[(6 - r) * 5 +: 5];
	end
endfunction

function [2:0] font3(input d3, input [2:0] r);        // 2 or 3, row r, bit 2 = left
	reg [14:0] g;
	begin
		g = d3 ? {3'b111, 3'b001, 3'b111, 3'b001, 3'b111}
		       : {3'b111, 3'b001, 3'b111, 3'b100, 3'b111};
		font3 = g[(4 - r) * 3 +: 3];
	end
endfunction

function glyph(input [4:0] u, input [3:0] v, input [3:0] k, input [1:0] l);
	reg [4:0] row5;
	reg [2:0] row3;
	reg [2:0] c;
	reg [1:0] s;
	reg [2:0] col;
	reg       in_sq;
	begin
		glyph = 1'b0;
		c     = (k < 4'd4) ? k[2:0] : (k[0] ? 3'd5 : 3'd4);
		in_sq = 1'b1;
		s     = 2'd0;
		col   = 3'd0;
		if      (u >= 5'd11 && u <= 5'd15) begin s = 2'd0; col = u - 5'd11; end
		else if (u >= 5'd17 && u <= 5'd21) begin s = 2'd1; col = u - 5'd17; end
		else if (u >= 5'd23 && u <= 5'd27) begin s = 2'd2; col = u - 5'd23; end
		else in_sq = 1'b0;
		if (u >= 5'd1 && u <= 5'd5 && v >= 4'd1 && v <= 4'd7) begin
			row5  = font5(c, v - 4'd1);
			glyph = row5[5'd5 - u];
		end else if (u >= 5'd7 && u <= 5'd9 && v >= 4'd3 && v <= 4'd7 && k >= 4'd6) begin
			row3  = font3(k >= 4'd8, v - 4'd3);
			glyph = row3[5'd9 - u];
		end else if (in_sq && v >= 4'd2 && v <= 4'd6) begin
			if (l == 2'd0) glyph = (col == 3'd0) || (col == 3'd4) || (v == 4'd2) || (v == 4'd6);
			else           glyph = (l > s);
		end
	end
endfunction

// ---- counters and decision for the next pixel
reg [10:0] a1 = 0, a2 = 0, b1 = 0, b2 = 0;
reg        d_hit = 0, d_on = 0;

wire [10:0] sa  = sa_n ? 11'h7FF : 11'h001;
wire [10:0] sb  = sb_n ? 11'h7FF : 11'h001;
wire  [4:0] na  = q[0] ? 5'(BH) : 5'(BW);
wire  [4:0] nb  = q[0] ? 5'(BW) : 5'(BH);
// The decision for the next pixel, for a coordinate along the row (c1, c2):
// {hit, on}. It is computed for both possible values, a1/a2 (de high) and
// a0_1/a0_2 (end of row: first pixel of the next one), and de selects at the
// end: de arrives late (from the core video), so it is kept out of the glyph
// logic. All inputs are passed as arguments (pure function).
function [1:0] decide(input [10:0] c1, input [10:0] c2, input [10:0] r1, input [10:0] r2,
                      input [7:0] n1, input [7:0] n2, input qq, input [4:0] ma, input [4:0] mb,
                      input [3:0] kk1, input [1:0] ll1, input [3:0] kk2, input [1:0] ll2);
	reg       i1, i2;
	reg [4:0] uu1, uu2;
	reg [3:0] vv1, vv2;
	begin
		i1  = (n1 != 8'd0) && (c1[10:5] == 6'd0) && (c1[4:0] < ma) && (r1[10:5] == 6'd0) && (r1[4:0] < mb);
		i2  = (n2 != 8'd0) && (c2[10:5] == 6'd0) && (c2[4:0] < ma) && (r2[10:5] == 6'd0) && (r2[4:0] < mb);
		uu1 = qq ? r1[4:0] : c1[4:0];
		vv1 = qq ? c1[3:0] : r1[3:0];
		uu2 = qq ? r2[4:0] : c2[4:0];
		vv2 = qq ? c2[3:0] : r2[3:0];
		decide = {i1 | i2, i2 ? glyph(uu2, vv2, kk2, ll2) : glyph(uu1, vv1, kk1, ll1)};
	end
endfunction
wire [1:0] dec_de = decide(a1,   a2,   b1, b2, tm1, tm2, q[0], na, nb, k1, l1, k2, l2);
wire [1:0] dec_nd = decide(a0_1, a0_2, b1, b2, tm1, tm2, q[0], na, nb, k1, l1, k2, l2);
wire [1:0] dec    = de ? dec_de : dec_nd;

always @(posedge clk) begin
	if (ce_pix) begin
		de_q <= de;
		vs_q <= vsa;
		if (de) begin a1 <= a1 + sa;   a2 <= a2 + sa;   end
		else    begin a1 <= a0_1 + sa; a2 <= a0_2 + sa; end
		if (vsa & ~vs_q)       begin b1 <= b0_1;      b2 <= b0_2;      end
		else if (de_q && !de)  begin b1 <= b1 + sb;   b2 <= b2 + sb;   end
		d_hit <= dec[1];
		d_on  <= dec[0];
	end
end

assign r_out = d_hit ? {8{d_on}} : r_in;
assign g_out = d_hit ? {8{d_on}} : g_in;
assign b_out = d_hit ? {8{d_on}} : b_in;

endmodule
