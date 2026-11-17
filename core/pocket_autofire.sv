// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) Umberto Parisi (rmonic79).
//
// pocket_autofire -- autofire for the Pocket, as Main_MiSTer does it on MiSTer
// (there: button held + Menu; on the Pocket the Analogue button does not reach the
// core, so Select acts as "Menu").
//
//   Select held + game button: the rate of that button steps
//   off -> 10 -> 15 -> 30 shots/s -> off.
//   With the rate active, WHILE the button is pressed the core sees pressed/released
//   alternating on core frames (VSync): 10 = 3+3, 15 = 2+2, 30 = 1+1, with the first
//   pressed frame right at the press. With the button released, nothing.
//
//   Select: while held it does not reach the core. Released without having set any
//   button, it arrives as a pulse of SEL_PULSE frames (in arcade games it is the
//   coin: inserted on release). If a button was set, it does not arrive.
//   The button pressed with Select held does not reach the core until it is released.
//
// Buttons that can autofire: A B X Y L1 R1 L2 R2 L3 R3 (bits 4-13 of cont*_key).
// D-pad, Select and Start pass unchanged (Select as above). Bits [31:16] unchanged.
//
// For the on-screen indicator (pocket_af_osd): on every setting ev_tog toggles and
// ev_key/ev_lvl give the button (0 = A ... 9 = R3) and the new rate; they stay
// unchanged until the next setting.
module pocket_autofire #(
	parameter integer SEL_PULSE = 3
) (
	input             clk,
	input             frame,     // 1 cycle per core frame
	input      [31:0] key_in,    // Pocket buttons (cont*_key)
	output     [31:0] key_out,   // to map_joy
	output reg        ev_tog = 0,
	output reg  [3:0] ev_key = 0,
	output reg  [1:0] ev_lvl = 0
);

localparam integer B0 = 4, B1 = 13, NK = 10;   // buttons that can autofire
localparam integer SEL = 14;

// "pressed" frames over the 12 phases from the press (bit = phase):
//   10/s = 3 pressed + 3 released, 15/s = 2 + 2, 30/s = 1 + 1
localparam [15:0] ON10 = 16'b0000_0001_1100_0111;   // phases 0-2, 6-8
localparam [15:0] ON15 = 16'b0000_0011_0011_0011;   // phases 0-1, 4-5, 8-9
localparam [15:0] ON30 = 16'b0000_0101_0101_0101;   // even phases

reg   [1:0] level [0:NK-1];          // 0 off, 1 = 10/s, 2 = 15/s, 3 = 30/s
reg   [3:0] phase [0:NK-1];          // frames since the press, modulo 12
reg [NK-1:0] cfg_mask = 0;           // button pressed during the setting: hidden until released
reg  [15:0] key_q = 0;
reg         sel_used = 0;
reg   [3:0] sel_cnt = 0;             // Select pulse on release, in frames
integer i, j;

initial for (i = 0; i < NK; i = i + 1) begin level[i] = 2'd0; phase[i] = 4'd0; end

wire          sel     = key_in[SEL];
wire [NK-1:0] k       = key_in[B1:B0];
wire [NK-1:0] press   = k & ~key_q[B1:B0];          // buttons just pressed
wire [NK-1:0] set_cfg = press & {NK{sel}};          // ... with Select held: setting

// set button with the highest index (if two arrive on the same clock)
reg  [3:0] hi;
reg        any;
always @* begin
	hi  = 4'd0;
	any = 1'b0;
	for (j = 0; j < NK; j = j + 1)
		if (set_cfg[j]) begin hi = j[3:0]; any = 1'b1; end
end

function on_now(input [1:0] lv, input [3:0] ph);
	case (lv)
		2'd1:    on_now = ON10[ph];
		2'd2:    on_now = ON15[ph];
		2'd3:    on_now = ON30[ph];
		default: on_now = 1'b1;
	endcase
endfunction

always @(posedge clk) begin
	key_q <= key_in[15:0];
	if (sel && !key_q[SEL]) sel_used <= 1'b0;
	if (any) begin
		sel_used <= 1'b1;
		ev_key   <= hi;
		ev_lvl   <= level[hi] + 2'd1;
		ev_tog   <= ~ev_tog;
	end
	for (i = 0; i < NK; i = i + 1) begin
		if (set_cfg[i]) level[i] <= level[i] + 2'd1;  // 3 -> 0 by wrap-around
		if (press[i])                phase[i] <= 4'd0;
		else if (frame && k[i])      phase[i] <= (phase[i] == 4'd11) ? 4'd0 : phase[i] + 4'd1;
		cfg_mask[i] <= set_cfg[i] | (cfg_mask[i] & k[i]);
	end
	// Select released without any setting: pulse to the core
	if (!sel && key_q[SEL] && !sel_used) sel_cnt <= SEL_PULSE[3:0];
	else if (frame && sel_cnt != 4'd0)   sel_cnt <= sel_cnt - 4'd1;
end

genvar g;
generate
	for (g = 0; g < 32; g = g + 1) begin : gk
		if (g >= B0 && g <= B1) begin : gb
			assign key_out[g] = k[g-B0] && !cfg_mask[g-B0] && on_now(level[g-B0], phase[g-B0]);
		end else if (g == SEL) begin : gs
			assign key_out[g] = (sel_cnt != 4'd0);
		end else begin : gp
			assign key_out[g] = key_in[g];
		end
	end
endgenerate

endmodule
