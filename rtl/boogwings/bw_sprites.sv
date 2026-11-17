// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of BoogieWings_MiSTer.
    GPL-3.
    Author: Umberto Parisi (rmonic79)
*/
//
// bw_sprites — DECO_SPRITE (DECO52) engine, SCANLINE-BASED.
// Engine shared with Night Slashers and Tattoo Assassins (there it is called
// ns_sprites): same logic, name matching the core that hosts it.
//
// MAME equivalent: full-frame 320×256 m_sprite_bitmap + draw_sprites_common.
// A full-frame double buffer does not fit in M10K (160 blocks needed) →
// SCANLINE-BASED architecture with line buffers.
//
// Pattern:
//   - Per chip, one line-buffer RAM holding a ring of 12 buffers of 320 pixels
//     (see "Line buffer ring" below).
//   - A scan FSM checks the 256 sprites against the target line and queues the
//     matches in a FIFO; the draw FSM pops them.
//   - For each sprite, intersection check of the target scanline with the bounding box
//     (ypos..ypos+16*(multi+1)-1). If it hits, ROM fetch for the correct row and
//     draw of 16 columns into the buffer under construction (x = sx..sx+15).
//   - Active area render: pxl* = buffer in display [render_x]
//   - Elastic pipeline: buffers are consumed only at hblank, the draw works up to
//     10 lines ahead during active video, legacy pacing in vblank.
//
// Output identical to MAME m_sprite_bitmap if the scan is ordered correctly.
// Race-free by construction (the draw writes the buffer under construction, the
// render reads the buffer in display, never the same one).
//
// MAME standard format (offs +0/+1/+2):
//   +0: efFbSssyyyyyyyyy  e=priority, f=flipy, F=flipx, b=flash, S=w, ss=h
//   +1: tttttttttttttttt  tile code
//   +2: ppcccccxxxxxxxxx  pp=priority, ccccc=color (5b), x=xpos
//
// Pen extraction:
//   pen[3]=byte[3], pen[2]=byte[2], pen[1]=byte[1], pen[0]=byte[0]

module bw_sprites #(
	// NS chip0 sprites are 5bpp: SPR0_5BPP=1 adds a 5th plane fetched from the
	// rom0_p4_* channel and widens pxl0 to {color[7:0], pen[4:0]} (13-bit).
	// Default 0 = Boogie Wings behaviour (4bpp, pxl 12-bit) — unchanged.
	parameter SPR0_5BPP = 0,
	// PARALLEL SCAN: the two DECO chips are INDEPENDENT on the real hardware;
	// scanning them in SERIES (chip0 then chip1 in the same line window) doubles
	// the time.
	// CHIP_ONLY: 2'b00 = both (serial), 2'b01 = chip0 only, 2'b10 = chip1
	// only -> two parallel instances = scan time per line HALVED.
	parameter [1:0] CHIP_ONLY = 2'b00
) (
	input  wire        clk,
	input  wire        reset,

	// VRAM read port chip0/chip1
	output reg  [9:0]  sram0_addr,
	input  wire [15:0] sram0_data,
	output reg  [9:0]  sram1_addr,
	input  wire [15:0] sram1_data,

	// ROM read port chip0/chip1 (toggle protocol)
	output reg  [23:0] rom0_addr,
	output reg         rom0_req,
	input  wire [31:0] rom0_data,
	input  wire        rom0_valid,
	output reg  [23:0] rom1_addr,
	output reg         rom1_req,
	input  wire [31:0] rom1_data,
	input  wire        rom1_valid,

	// NS chip0 5th-plane fetch channel (only used when SPR0_5BPP=1). 1 byte/group.
	output reg  [23:0] rom0_p4_addr,
	output reg         rom0_p4_req,
	input  wire [7:0]  rom0_p4_data,
	input  wire        rom0_p4_valid,

	// Video timing
	input  wire  [9:0] render_x,
	input  wire  [9:0] render_y,
	input  wire        hblank_in,
	input  wire        vblank_in,
	input  wire        ce_pix,
	input  wire        pause_in,      // frame-aligned pause: freezes frame_odd (sprite flash)
	input  wire        flip_screen,

	// OSD toggles (decode permutations)
	input  wire        osd_spr_swap_hl,
	input  wire        osd_spr_brev8,
	input  wire        osd_spr_nibsw,
	input  wire        osd_spr_bs_ab,

	// === EXTRA spr permutation OSD (for BG sprite decoder debug) ===
	input  wire        osd_spr_msb_first,    // bit_x: 1=MSB first (7-pix), 0=LSB first (pix)
	input  wire        osd_spr_half_inv,     // swaps the logical half (left/right)
	input  wire        osd_spr_half_eff_inv, // swaps the EFFECTIVE half at the ROM fetch
	input  wire        osd_spr_row_inv,      // 15 - row_in_tile (Y flip inside the tile)
	input  wire        osd_spr_plane_inv,    // bit-reverse of the pen nibble (= reverse plane order)
	input  wire [1:0]  osd_spr_p0_src,       // which byte of the 32-bit fetch plane 0 is taken from (LSB nibble)
	input  wire [1:0]  osd_spr_p1_src,
	input  wire [1:0]  osd_spr_p2_src,
	input  wire [1:0]  osd_spr_p3_src,
	input  wire        osd_spr_w_swap_pos,          // w-mode: swaps the position of the 1st/2nd block
	input  wire        osd_spr_w_offset_first,      // w-mode: applies the offset to the 1st block (absolute X debug)
	input  wire        osd_spr_w_code_swap,         // w-mode: swaps first/second code
	input  wire signed [3:0] osd_spr_w_offset,      // w-mode: signed X offset (step 16)

	// Pixel output (12-bit = {color[7:0], pen[3:0]})
	output wire [12:0] pxl0,    // {color[7:0], pen[4:0]} when SPR0_5BPP, else pen[3:0] in [3:0]
	output wire [11:0] pxl1,
	// Transparent layer of chip1 (smoke/explosions), kept separate from pxl1
	// so the mixer can blend it over the opaque pixel underneath instead of
	// losing that pixel. See the comment on linebuf_spr1_a.
	output wire [11:0] pxl1_alpha
);

// flipscreen sprite — MAME boogwing.cpp:424 set_flip_screen(!BIT(flip,7))
// → ALWAYS inverted with respect to the flip_screen input (= tilemap flip).
// Default boogwing (DSW flip=Off, flip_screen=0): flipscreen_spr=1 → identity coord.
wire flipscreen_spr = ~flip_screen;

// ============================================================
// HBlank edge detect — triggers the scan for the next scanline
// ============================================================
reg hblank_d;
always @(posedge clk) hblank_d <= hblank_in;
wire hbl_rise = hblank_in & ~hblank_d;

// Go-latch: captures hbl_rise even if the FSM is in the middle of a sprite.
// Without the latch the edge is lost → scanline NOT scanned → render reads a
// stale buffer → "unstable" sprite tiles even in pause (= edge lost at random
// depending on how saturated with sprites the previous scanline was).
// Same pattern as pf*_go_latch in deco16ic_jt.
reg       go_latch;
reg [9:0] latched_render_y;
// SHADOW SCAN: line start common to BOTH FSMs (scan + draw), defined
// after the state declarations (assign further below).
wire      line_start;

// Frame parity for the sprite FLASH (MAME decospr.cpp:227: flag y_word[12], the sprite
// is hidden on ODD frames -> if(!(flash && (frame_number & 1))) draw). Toggles at
// every vblank rise = frame_number[0].
reg       vblank_in_d;
reg       frame_odd;
always @(posedge clk) begin
	if (reset) begin
		vblank_in_d <= 1'b0;
		frame_odd   <= 1'b0;
	end else begin
		vblank_in_d <= vblank_in;
		// ~pause_in: in pause vblank keeps running (display alive) but the frame parity
		// stays still -> the FLASH freezes as on PCB/MAME (no flicker in pause).
		if (vblank_in & ~vblank_in_d & ~pause_in) frame_odd <= ~frame_odd;  // 1 toggle per frame
	end
end

// ============================================================
// Line buffer ring — ELASTIC PIPELINE, 12 buffers per chip (lead up to 10).
// Buffers are consumed ONLY at hbl_rise (never a swap in the middle of a line:
// that would show half of one buffer and half of another, i.e. lines that
// move in congested areas, from DDR3 latency jitter around the deadline).
// During active video the draw works up to 10 lines ahead (amortised budget:
// heavy lines spend the margin accumulated on light ones, jitter is absorbed);
// in vblank the pacing is legacy (1 start per hbl, empty queue: no change
// around the sprite RAM DMA and the frame wrap).
// Positional: disp = buffer in display; fill = READY buffers (0..10);
// build = disp + fill + 1 (mod 12) = buffer under construction.
// With fill<=10 -> build != disp ALWAYS (fill+1 never 0 mod 12) -> the render
// NEVER reads the buffer under construction = no tearing from collisions.
// disp ALWAYS points to a COMPLETE buffer (fill counts only done_ok) ->
// an incomplete buffer is never shown. NO ABORT (it would be another source of tearing).
// Underrun (small fill) -> disp advances slowly = REPEAT (never tearing).
// ONE RAM per chip: the 12 buffers side by side with a stride of 320, because
// only x 0..319 is ever written by the draw (xpos_s < 320).
// Buffer k = rows [k*320, k*320+319]. Write port = build, read port = disp,
// never the same buffer (fill<=10).
localparam [11:0] LB_STRIDE = 12'd320;
localparam [11:0] LB_LAST   = 12'd3520;   // 11*320: base of the last buffer
(* ramstyle = "M10K", no_rw_check *) reg [12:0] linebuf_spr0 [0:3839];
(* ramstyle = "M10K", no_rw_check *) reg [11:0] linebuf_spr1 [0:3839];
// Second layer of chip1, for TRANSPARENT pixels (smoke, explosions).
// Without it, a transparent pixel overwrites in the buffer the opaque one
// underneath: when the mixer blends, it finds nothing underneath and the
// covered object DISAPPEARS instead of showing through. Example: power-ups
// (sprites #112-113) and the elephant (#0-9), opaque, covered by smoke of the
// SAME chip at higher indices. With two separate layers both pixels reach the
// mixer and the blend has a real base.
// The layer is chosen by colour: bit 4 (= pix2 bit 8) or bit 7 (= pix2 bit 11),
// the same bits the mixer uses to decide to apply the ACE alpha LUTs.
(* ramstyle = "M10K", no_rw_check *) reg [11:0] linebuf_spr1_a [0:3839];

// 12 BUFFERS (lead 10). mod 12: build = disp+fill+1 (>=12 -> -12).
// fill<=10 -> build != disp ALWAYS. More lead = more heavy lines absorbed.
// The bases (buffer*320) are kept in registers: disp advances by one buffer at
// every cons; build = disp+fill+1 and disp+fill grows only with done_ok (cons
// advances disp and decrements fill), so build advances by one buffer at every
// done_ok and nothing else.
reg  [3:0] fill;                          // 0..10
reg [11:0] disp_base, build_base;
reg [9:0] clear_idx;

// done_ok = completion (S_DONE): the buffer enters the queue (fill++).
// Consume at hbl: if a buffer is ready (or one arrives in the same cycle).
wire done_ok;      // defined after state/S_DONE
wire cons = hbl_rise && ((fill != 4'd0) || done_ok);
always @(posedge clk) begin
	if (reset) begin
		fill       <= 4'd0;
		disp_base  <= 12'd0;
		build_base <= LB_STRIDE;           // build = disp+0+1 = buffer 1
	end else begin
		if (cons)    disp_base  <= (disp_base  == LB_LAST) ? 12'd0 : (disp_base  + LB_STRIDE);
		if (done_ok) build_base <= (build_base == LB_LAST) ? 12'd0 : (build_base + LB_STRIDE);
		fill <= fill + {3'd0, done_ok} - {3'd0, cons};
	end
end

// ============================================================
// Renderer read — disp_base stable for the whole line (advances only at hbl, never
// mid-scanline). x >= 320 has no rows in the RAM: the output is 0 (the draw never
// writes those columns).
// ============================================================
wire [11:0] lb_raddr = disp_base + {3'd0, render_x[8:0]};
reg  [12:0] lb0_q;
reg  [11:0] lb1_q;
reg  [11:0] lb1a_q;
reg         rx_out_d;
always @(posedge clk) lb0_q    <= linebuf_spr0[lb_raddr];
always @(posedge clk) lb1_q    <= linebuf_spr1[lb_raddr];
always @(posedge clk) lb1a_q   <= linebuf_spr1_a[lb_raddr];
always @(posedge clk) rx_out_d <= (render_x[8:0] >= 9'd320);

reg [12:0] pxl0_r;
reg [11:0] pxl1_r;
reg [11:0] pxl1a_r;
always @(posedge clk) pxl0_r  <= rx_out_d ? 13'd0 : lb0_q;
always @(posedge clk) pxl1_r  <= rx_out_d ? 12'd0 : lb1_q;
always @(posedge clk) pxl1a_r <= rx_out_d ? 12'd0 : lb1a_q;

assign pxl0      = pxl0_r;
assign pxl1      = pxl1_r;
assign pxl1_alpha = pxl1a_r;

// ============================================================
// Linebuf write port: the draw ALWAYS writes build (invariant under
// consume: cons does not move build -> never moved in the middle of a line).
// lb_waddr < 320 always (draw: xpos_s < 320; clear: 0..319).
// ============================================================
reg [8:0]  lb_waddr;
reg [12:0] lb_wdata;       // chip0 (5bpp) uses all 13 bits; chip1 uses [11:0]
reg [11:0] lb_wdata_a;     // transparent layer data: the pixel, or 0 to clear it
reg        lb_we0, lb_we1, lb_we1a;
wire [11:0] lb_waddr_full = build_base + {3'd0, lb_waddr};

always @(posedge clk) if (lb_we0)  linebuf_spr0  [lb_waddr_full] <= lb_wdata;
always @(posedge clk) if (lb_we1)  linebuf_spr1  [lb_waddr_full] <= lb_wdata[11:0];
always @(posedge clk) if (lb_we1a) linebuf_spr1_a[lb_waddr_full] <= lb_wdata_a;

// ============================================================
// Draw FSM: at each line start, draws the sprites matched for the target line
// ============================================================
reg [4:0]  state;
reg [9:0]  scan_y;          // = latched_render_y + 1 + fill (target scanline)
reg signed [9:0] sx_anchor;
reg signed [9:0] sy_signed;
reg [15:0] code_base;
reg [7:0]  color;
reg        flipy, flipx;
reg [2:0]  multi;           // 0/1/3/7 → 1/2/4/8 tiles tall
reg        w_mode;
reg        w_iter;
reg [3:0]  tile_idx;        // tile vertical idx (0..multi)
reg [3:0]  row_in_tile;     // row Y within tile (0..15)
reg        half;            // 0=cols 0..7, 1=cols 8..15
reg signed [9:0] sx_col;
reg        chip_idx;        // 0=chip0, 1=chip1

localparam [4:0]
	S_IDLE      = 5'd0,
	S_CLEAR     = 5'd1,
	S_POP       = 5'd2,   // SHADOW SCAN: pops a match from the FIFO
	S_FIND_ROW  = 5'd6,   // Computes whether the sprite intersects the scanline + tile_idx + row_in_tile
	S_ROM_REQ   = 5'd7,
	S_ROM_WAIT  = 5'd8,
	S_DRAW      = 5'd9,
	S_NEXT_HALF = 5'd10,
	S_NEXT_W    = 5'd11,
	S_NEXT_SPR  = 5'd12,
	S_FLUSH     = 5'd13,  // waits for the draw engine to finish before closing the line
	S_DONE      = 5'd14;

// done_ok: completion (S_DONE) -> buffer queued (fill++). NO ABORT: the
// draw is never truncated; on underrun disp stays put = repeat (never
// tearing). disp always points to a complete buffer (fill counts only done_ok).
assign done_ok = (state == S_DONE);

// go_latch always block — captures hbl_rise even if the FSM is not in S_IDLE.
// Without the latch the edge is lost while the FSM is still processing scanline N →
// scanline N+1 not scanned → render reads a stale buffer = unstable sprites even in pause.
always @(posedge clk) begin
	if (reset) begin
		go_latch <= 1'b0;
		latched_render_y <= 10'd0;
	end else begin
		if (hbl_rise) begin
			go_latch <= 1'b1;
			latched_render_y <= render_y;
		end else if (line_start) begin
			// SHADOW SCAN: consumed when BOTH FSMs are ready
			go_latch <= 1'b0;
		end
	end
end

// MAME decospr.cpp:267-282 + 297-314 — complete boogwing formula with flipscreen=ON:
//
//   STEP 1 (lines 267-282): y = 240 - sign_ext_256(y_sram); x = 304 - sign_ext_320(x_sram)
//   STEP 2 (lines 297-304, flipscreen=ON): y = 240 - y  (double inversion = y_sram_signed)
//   STEP 3 (lines 306-314, flipscreen=ON): x = 304 - x  (double inversion = x_sram_signed)
//
// → With flipscreen=ON (boogwing default): y_final = signed(y_sram), x_final = signed(x_sram).
// → With flipscreen=OFF (DSW flip): y_final = 240 - signed(y_sram), x_final = 304 - signed(x_sram).
//
// MAME boogwing.cpp:424 set_flip_screen(!BIT(flip,7)) → default ON (flip[7]=0).
//
// `mult` changes too: flipscreen=ON uses mult=+16 (tiles grow downwards),
// flipscreen=OFF uses mult=-16 (tiles grow upwards). fx/fy are inverted.
function signed [9:0] sxy_decode_y(input [8:0] raw);
	// Sign extension only: signed(y_sram). flip_screen is applied later in the FSM.
	begin
		sxy_decode_y = {{1{raw[8]}}, raw};
	end
endfunction

function signed [9:0] sxy_decode_x(input [8:0] raw);
	// "Sign-ext" only, with threshold 320 (MAME decospr.cpp:267-269):
	//   x = x & 0x1ff;            (9-bit 0..511)
	//   if (x >= 320) x -= 512;   (0..319 unsigned, 320..511 → -192..-1)
	// Result: signed -192..319 (10-bit signed is enough).
	// flip_screen is applied later in the FSM (304 - x if OFF, identity if ON).
	begin
		if (raw >= 9'd320)
			sxy_decode_x = $signed({1'b1, raw[8:0]});   // -192..-1
		else
			sxy_decode_x = {1'b0, raw};                  // 0..319
	end
endfunction

// ============================================================
// SHADOW SCAN (anti-bubbling: saves ~1800 clk per line).
// SEPARATE scan FSM that scans the 256 sprites and queues the MATCHES in a
// FIFO while the draw FSM draws: the serial scan leaves the critical
// path. Push order = scan order (chip0 then chip1, ascending entries)
// -> visual priority preserved. Fast Y skip and empty-entry test as in a
// serial scan.
// The FIFO (128 matches, well beyond what can be drawn in one line) stalls the
// scan when full: no match lost by construction.
// ============================================================
localparam [2:0] SC_IDLE = 3'd0, SC_A0 = 3'd1, SC_A1 = 3'd2, SC_A2 = 3'd3,
                 SC_D1 = 3'd4, SC_PUSH = 3'd5, SC_NEXT = 3'd6;
reg [2:0]  sc_state;
reg [9:0]  sc_off;
reg        sc_chip;
reg [15:0] sc_d0, sc_d1;
reg        scan_fin;
// Match FIFO: {chip, x_word, code_word, y_word} = 49 bit x 128 entries.
// MLAB: a scan->render FIFO in M10K has a read-during-write race on the
// hardware; MLAB (write-through LUTRAM) removes it.
(* ramstyle = "MLAB" *) reg [48:0] mfifo [0:127];
reg [7:0]  mf_w, mf_r;
reg [48:0] mf_q_r;
reg        mf_empty_d;
wire mf_empty = (mf_w == mf_r);
wire mf_full  = (mf_w[7] != mf_r[7]) && (mf_w[6:0] == mf_r[6:0]);
wire [15:0] sc_sram = sc_chip ? sram1_data : sram0_data;

// Production start (common to scan+draw):
// - ACTIVE video: free-run — as soon as both FSMs are idle and there is a
//   free buffer (fill<10) the next line starts (lead up to 10).
// - VBLANK: legacy pacing, same as a double buffer (1 start per hbl via
//   go_latch, empty queue): line 0 is rendered at the same hbl as with a
//   double buffer (after the sprite DMA) and the frame wrap is unchanged.
assign line_start = (state == S_IDLE) && (sc_state == SC_IDLE) &&
                    (vblank_in ? (go_latch && fill == 4'd0)
                               : (fill < 4'd10));

always @(posedge clk) begin
	// registered FIFO read; mf_empty_d = read-during-write guard:
	// the draw pops only entries written >=1 cycle earlier (mixed-port RDW undefined).
	mf_q_r     <= mfifo[mf_r[6:0]];
	mf_empty_d <= mf_empty;
end

always @(posedge clk) begin
	if (reset) begin
		sc_state   <= SC_IDLE;
		sc_off     <= 10'd0;
		sc_chip    <= 1'b0;
		scan_fin   <= 1'b1;
		mf_w       <= 8'd0;
		sram0_addr <= 10'd0;
		sram1_addr <= 10'd0;
	end else begin
		case (sc_state)
			SC_IDLE: if (line_start) begin
				sc_off   <= 10'd0;
				sc_chip  <= CHIP_ONLY[1];
				scan_fin <= 1'b0;
				mf_w     <= 8'd0;
				sc_state <= SC_A0;
			end
			SC_A0: begin
				if (sc_chip) sram1_addr <= sc_off;
				else         sram0_addr <= sc_off;
				sc_state <= SC_A1;
			end
			SC_A1: begin
				if (sc_chip) sram1_addr <= sc_off + 10'd1;
				else         sram0_addr <= sc_off + 10'd1;
				sc_state <= SC_A2;
			end
			SC_A2: begin
				// sc_sram = y_word. Fast Y skip.
				sc_d0 <= sc_sram;
				if (sc_chip) sram1_addr <= sc_off + 10'd2;
				else         sram0_addr <= sc_off + 10'd2;
				begin : sc_fast_skip
					reg signed [9:0] sy_pre;
					reg [2:0] multi_pre;
					reg [10:0] height;
					reg signed [10:0] dy_pre;
					reg signed [10:0] sy_top;
					sy_pre = sxy_decode_y(sc_sram[8:0]);
					case ({sc_sram[10], sc_sram[9]})
						2'd0: multi_pre = 3'd0;
						2'd1: multi_pre = 3'd1;
						2'd2: multi_pre = 3'd3;
						2'd3: multi_pre = 3'd7;
					endcase
					height = {7'd0, multi_pre, 4'b0} + 11'd16;
					// Topmost row occupied by the sprite. Without flip it is sy.
					// With flip MAME places the block at 240-sy and the following
					// blocks go upwards (mult=-16), so the top is
					// 240 - sy - 16*multi = 256 - sy - height: symmetric, not 0.
					// With sy_top=0 the fast reject would be disabled and every line
					// would go through all 256 sprites.
					sy_top = flipscreen_spr ? $signed({sy_pre[9], sy_pre})
					                        : (11'sd256 - $signed({sy_pre[9], sy_pre}) - $signed({1'b0, height}));
					dy_pre = $signed({scan_y[9], scan_y}) - sy_top;
					if (sc_sram == 16'd0)
						sc_state <= SC_NEXT;
					else if (sc_sram[12] && frame_odd)
						sc_state <= SC_NEXT;   // flash: off on odd frames
					else if (dy_pre < 0 || dy_pre >= $signed({1'b0, height}))
						sc_state <= SC_NEXT;
					else
						sc_state <= SC_D1;
				end
			end
			SC_D1: begin
				sc_d1 <= sc_sram;          // = code word
				sc_state <= SC_PUSH;
			end
			SC_PUSH: begin
				// sc_sram = x word (address held since SC_A2: stable during a stall).
				if (sc_d0 == 16'd0 && sc_d1 == 16'd0 && sc_sram == 16'd0) begin
					sc_state <= SC_NEXT;   // all-zero entry
				end else if (!mf_full) begin
					mfifo[mf_w[6:0]] <= {sc_chip, sc_sram, sc_d1, sc_d0};
					mf_w <= mf_w + 8'd1;
					sc_state <= SC_NEXT;
				end
				// mf_full: stall here until the draw frees space
			end
			SC_NEXT: begin
				if (sc_off >= 10'd1020) begin
					if (sc_chip == 1'b0 && CHIP_ONLY == 2'b00) begin
						sc_chip  <= 1'b1;
						sc_off   <= 10'd0;
						sc_state <= SC_A0;
					end else begin
						scan_fin <= 1'b1;
						sc_state <= SC_IDLE;
					end
				end else begin
					sc_off   <= sc_off + 10'd4;
					sc_state <= SC_A0;
				end
			end
			default: sc_state <= SC_IDLE;
		endcase
	end
end

// ROM permutations (OSD selectable)
function [7:0] brev8(input [7:0] b);
	brev8 = {b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]};
endfunction

wire [31:0] rom_data_cur  = chip_idx ? rom1_data : rom0_data;
wire        rom_valid_cur = chip_idx ? rom1_valid : rom0_valid;
// P4 fetch: it travels on a separate DDR port (slower than the main one: the
// arbiter serves rd4 first, then rd7). Waiting ONLY for rom_valid_cur, the
// first pixels of the group would read the STALE P4 byte of the previous
// group -> glitches/spurious tiles. p4_ok latches the arrival of P4.
reg         p4_ok;
// rom0/rom1_valid are 1-clk PULSES (the bridge clears them every clk) and P4
// always arrives AFTER the main data (arbiter: rd4 before rd7) -> "valid && p4_ok"
// is NEVER true in the same cycle -> the FSM would hang. The DATA stays stable in
// the bridge holding registers: the ARRIVALS are latched (rom_ok/p4_ok) and the
// wait looks at the latches.
reg         rom_ok;

// PREFETCH (anti-bubbling): the draw reads from the LATCHED COPY
// (rom_lat/p4_lat) instead of the bridge holding registers, so the fetch
// of half B starts WHILE half A is drawn (DDR round-trip hidden
// under the 8 px of draw). Bit-identical output: the copy == holding reg at
// latch time.
reg [31:0] rom_lat;
reg [7:0]  p4_lat;
// ── DECOUPLED DRAW ENGINE (cross-sprite prefetch) ──
// The draw of the 8 px runs in PARALLEL with the FSM: at dispatch (fetch arrival)
// the minimal context is snapshotted (rom_lat/p4_lat + these 5 regs) and the FSM
// continues AT ONCE with the address generation of the next group — B, column 2,
// or FIRST GROUP OF THE NEXT SPRITE — so every DDR round-trip (including the one
// at the boundary between sprites) runs under the 8 px being drawn.
// Bit-identical pixels: same data, same addresses, same order per group.
reg        d_busy;
reg [2:0]  d_pix;
reg signed [9:0] d_sx;
reg        d_half, d_chip, d_flipx;
reg [7:0]  d_color;
wire [31:0] rom_swap = osd_spr_swap_hl ? {rom_lat[15:0], rom_lat[31:16]} : rom_lat;
wire [31:0] rom_bsab = osd_spr_bs_ab ?
	{rom_swap[23:16], rom_swap[31:24], rom_swap[7:0], rom_swap[15:8]} :
	rom_swap;
wire [31:0] rom_nibsw = osd_spr_nibsw ?
	{rom_bsab[27:24], rom_bsab[31:28], rom_bsab[19:16], rom_bsab[23:20],
	 rom_bsab[11:8],  rom_bsab[15:12], rom_bsab[3:0],   rom_bsab[7:4]} :
	rom_bsab;
wire [31:0] rom_perm = osd_spr_brev8 ?
	{brev8(rom_nibsw[31:24]), brev8(rom_nibsw[23:16]),
	 brev8(rom_nibsw[15:8]),  brev8(rom_nibsw[7:0])} :
	rom_nibsw;

// fx_eff = flipx ^ flipscreen_spr (MAME lines 306-313: flipscreen inverted, m_flipallx=0)
// NB: fx_eff (from the FSM regs) is used ONLY by the address generation (half_use in
// S_ROM_REQ); the DRAW pen chain uses the snapshot d_flipx/d_pix (the draw runs in
// parallel while the FSM has already decoded the next sprite).
wire fx_eff = flipx ^ flipscreen_spr;
wire d_fx_eff = d_flipx ^ flipscreen_spr;
// MSB-first vs LSB-first selection runtime (osd_spr_msb_first)
wire [2:0] bit_x_lsb = d_fx_eff ? d_pix : (3'd7 - d_pix);
wire [2:0] bit_x_msb = d_fx_eff ? (3'd7 - d_pix) : d_pix;
wire [2:0] bit_x = osd_spr_msb_first ? bit_x_msb : bit_x_lsb;

// per-plane byte source selection: each plane chooses which of the 4 bytes of the 32-bit fetch it takes.
// boogwing default: p0=byte0, p1=byte1, p2=byte2, p3=byte3 (= [0..7], [8..15], [16..23], [24..31])
function [4:0] byte_base(input [1:0] src);
	case (src)
		2'd0: byte_base = 5'd0;
		2'd1: byte_base = 5'd8;
		2'd2: byte_base = 5'd16;
		2'd3: byte_base = 5'd24;
	endcase
endfunction
wire p0_bit = rom_perm[byte_base(osd_spr_p0_src) + {2'd0, bit_x}];
wire p1_bit = rom_perm[byte_base(osd_spr_p1_src) + {2'd0, bit_x}];
wire p2_bit = rom_perm[byte_base(osd_spr_p2_src) + {2'd0, bit_x}];
wire p3_bit = rom_perm[byte_base(osd_spr_p3_src) + {2'd0, bit_x}];

// MAME planeoffset = {hi+8, hi+0, lo+8, lo+0} → plane 0 = byte 3 (mbd-05 high),
// plane 1 = byte 2, plane 2 = byte 1, plane 3 = byte 0 (mbd-06 low).
// Default pen = {p3, p2, p1, p0} (= reversed).
// OSD plane_inv flips to the inverse order {p0, p1, p2, p3}.
wire [3:0] pen_raw = {p3_bit, p2_bit, p1_bit, p0_bit};
wire [3:0] draw_pen = osd_spr_plane_inv ? {pen_raw[0], pen_raw[1], pen_raw[2], pen_raw[3]} : pen_raw;

// NS chip0 5th plane (mbh-06): the rom0_p4 byte holds 8 px of plane 0 (= pen MSB).
// p4_bit for the current pixel; only meaningful on chip0 when SPR0_5BPP=1.
// PREFETCH: reads from the latched copy (see rom_lat).
wire p4_bit = p4_lat[bit_x];
// 5-bit pen for the NS 5bpp path: plane0(mbh06)=MSB, then planes1..4 = draw_pen.
// draw_pen[3:0] are the 4 normal planes (mbh-02/04). MAME order: pen={p4,planes1..4}.
wire [4:0] draw_pen5 = {p4_bit, draw_pen};
// transparency: chip0 5bpp tests the 5-bit pen, everything else the 4-bit pen.
// (d_chip: snapshot at dispatch — the FSM may have already changed chip_idx.)
wire pen_nonzero = ((SPR0_5BPP != 0) && !d_chip) ? (draw_pen5 != 5'd0)
                                                 : (draw_pen != 4'd0);

// ============================================================
// FSM
// ============================================================
always @(posedge clk) begin
	if (reset) begin
		state      <= S_IDLE;
		lb_we0     <= 1'b0;
		lb_we1     <= 1'b0;
		lb_we1a    <= 1'b0;
		rom0_req   <= 1'b0;
		rom1_req   <= 1'b0;
		rom0_p4_req  <= 1'b0;
		rom0_p4_addr <= 24'd0;
		p4_ok      <= 1'b1;
		rom_ok     <= 1'b1;
		// SHADOW SCAN: sram0/1_addr are driven ONLY by the scan FSM
		mf_r       <= 8'd0;
		chip_idx   <= 1'b0;
		d_busy     <= 1'b0;
		d_pix      <= 3'd0;
	end else begin
		lb_we0 <= 1'b0;
		lb_we1 <= 1'b0;
		lb_we1a <= 1'b0;
		// PREFETCH: default clear of the reqs every cycle -> every request (from
		// S_ROM_REQ) lasts EXACTLY 1 clk
		// (the assignment in the state, later in the source, wins that cycle).
		rom0_req    <= 1'b0;
		rom1_req    <= 1'b0;
		rom0_p4_req <= 1'b0;
		// Latch of the ARRIVALS (the valids are 1-clk pulses; the data stays in the
		// bridge holding registers). The clear on a new request is in S_ROM_REQ
		// (later assignment in the source = wins that cycle).
		if (rom0_p4_valid)  p4_ok  <= 1'b1;
		if (rom_valid_cur)  rom_ok <= 1'b1;

		// ── DRAW ENGINE (parallel to the FSM, atomic group of 8 px) ──
		// Writes the line buffer from the context snapshotted at dispatch (d_*).
		// Never in conflict with S_CLEAR: the clear precedes every dispatch.
		if (d_busy) begin
			begin : draw_engine
				reg signed [10:0] xpos_s;
				reg signed [10:0] sx_ext;
				reg signed [10:0] pix_ext;
				sx_ext  = $signed({d_sx[9], d_sx});
				pix_ext = $signed({7'b0, d_half ^ osd_spr_half_inv, d_pix});
				xpos_s  = sx_ext + pix_ext;
				if (pen_nonzero
				    && xpos_s >= 11'sd0 && xpos_s < 11'sd320) begin
					lb_waddr <= xpos_s[8:0];
					lb_wdata <= ((SPR0_5BPP != 0) && !d_chip)
					            ? {d_color, draw_pen5}
					            : {1'b0, d_color, draw_pen};
					// chip1: pixels with the alpha bits (colour bit 4 or 7) go
					// to the transparent layer, the others to the opaque one.
					//
					// LIST ORDER REMAINS THE RULE. An opaque pixel that
					// arrives LATER must cover the transparent one, so its
					// write CLEARS the transparent layer at that
					// position. This way "there is something in the transparent
					// layer" means exactly "it arrived after the last
					// opaque pixel", which is the chip's precedence.
					// Without the clear, half the scene (all sprites with
					// bit 13 set, which is a COLOUR bit) would jump over the
					// others regardless of the order: e.g. in the airship
					// room 51 sprites out of 92 have that bit.
					// NB: from the EXPRESSION, not from lb_wdata, which in this
					// cycle still holds the old value (non-blocking).
					lb_wdata_a <= {d_color, draw_pen};
					if (d_chip) begin
						if (d_color[4] | d_color[7]) begin
							lb_we1a <= 1'b1;         // transparent pixel
						end else begin
							lb_we1     <= 1'b1;      // opaque pixel
							lb_we1a    <= 1'b1;      // ...which clears the transparent one
							lb_wdata_a <= 12'd0;
						end
					end else begin
						lb_we0 <= 1'b1;
					end
				end
			end
			if (d_pix == 3'd7) d_busy <= 1'b0;
			else               d_pix  <= d_pix + 3'd1;
		end

		case (state)
			S_IDLE: begin
				if (line_start) begin
					// ELASTIC: target = line the display will request in
					// (1+fill) hbl = latched_render_y + 1 + fill. With fill=0 it is
					// the legacy behaviour (latched+1, including the behaviour at the
					// frame wrap in vblank); with fill>0 the work runs ahead (max +10).
					scan_y     <= latched_render_y + 10'd1 + {8'd0, fill};
					mf_r       <= 8'd0;
					clear_idx  <= 10'd0;
					state      <= S_CLEAR;
				end
			end

			S_CLEAR: begin
				// Clear the buffer under construction (both chips in parallel, and the
				// transparent layer of chip1 together with its opaque one).
				lb_we0     <= 1'b1;
				lb_we1     <= 1'b1;
				lb_we1a    <= 1'b1;
				lb_waddr   <= clear_idx[8:0];
				lb_wdata   <= 13'h000;
				lb_wdata_a <= 12'd0;
				if (clear_idx == 10'd319) begin
					state       <= S_POP;
				end else begin
					clear_idx <= clear_idx + 10'd1;
				end
			end

			S_POP: begin
				// SHADOW SCAN: pops the next match from the FIFO. mf_q_r is
				// the registered read of mfifo[mf_r]: valid because mf_r has
				// been stable for >=1 cycle; mf_empty_d (delayed) guarantees that
				// the entry was written >=1 cycle earlier (RDW guard).
				// Sprite decode, sources from the FIFO:
				// entry = {chip[48], x_word[47:32], code_word[31:16], y_word[15:0]}.
				if (!mf_empty && !mf_empty_d) begin
					chip_idx <= mf_q_r[48];
					flipy    <= mf_q_r[14];
					flipx    <= mf_q_r[13];
					w_mode   <= mf_q_r[11];
					begin : decode_h
						reg [1:0] hbits;
						hbits = {mf_q_r[10], mf_q_r[9]};
						case (hbits)
							2'd0: multi <= 3'd0;
							2'd1: multi <= 3'd1;
							2'd2: multi <= 3'd3;
							2'd3: multi <= 3'd7;
						endcase
					end
					color     <= {mf_q_r[15], mf_q_r[47:41]};
					code_base <= mf_q_r[31:16];
					w_iter    <= 1'b0;
					begin : decode_xy
						reg signed [9:0] sy_d;
						reg signed [9:0] sx_d;
						reg signed [9:0] anchor_base;
						reg signed [9:0] sx_first;
						sy_d = sxy_decode_y(mf_q_r[8:0]);
						sx_d = sxy_decode_x(mf_q_r[40:32]);
						// flipscreen_spr applied: if ON, identity (= sy_d, sx_d).
						// If OFF, MAME double inversion (240-y, 304-x).
						if (flipscreen_spr) begin
							sy_signed   <= sy_d;
							anchor_base = sx_d;
						end else begin
							sy_signed   <= $signed(10'sd240) - sy_d;
							anchor_base = $signed(10'sd304) - sx_d;
						end
						sx_anchor <= anchor_base;
						if (osd_spr_w_swap_pos)
							sx_first = anchor_base
							           + (flipscreen_spr ? 10'sd16 : -10'sd16)
							           + ({{6{osd_spr_w_offset[3]}}, osd_spr_w_offset, 4'd0});
						else if (osd_spr_w_offset_first)
							sx_first = anchor_base + ({{6{osd_spr_w_offset[3]}}, osd_spr_w_offset, 4'd0});
						else
							sx_first = anchor_base;
						sx_col    <= sx_first;
					end
					mf_r  <= mf_r + 8'd1;
					state <= S_FIND_ROW;
				end else if (mf_empty && scan_fin) begin
					// FIFO empty AND scan finished: line complete (S_FLUSH waits for
					// a last draw that may still be running)
					state <= S_FLUSH;
				end
				// FIFO empty but scan still running: wait here
			end

			S_FIND_ROW: begin
				// MAME decospr.cpp:297-304:
				//   flipscreen OFF: mult = -16, tiles grow upwards from sy
				//     → bounding box [sy - 16*multi, sy + 16)
				//     → dy_top = scan_y - (sy - 16*multi) = (scan_y - sy) + 16*multi
				//   flipscreen ON:  mult = +16, tiles grow downwards from sy
				//     → bounding box [sy, sy + 16*(multi+1))
				//     → dy_top = scan_y - sy
				// fy_eff = flipy ^ flipscreen_spr  (MAME line 300: if (fy) fy=0; else fy=1)
				//
				// tile_idx = "visual position of the tile inside the multi sprite" (0=top).
				// = dy_u[6:4] ALWAYS (the fy flip does NOT go here, it goes on the code in S_ROM_REQ).
				// row_in_tile = Y row inside the tile, inverted if fy_eff (= row flip of the tile).
				begin : isect_calc
					reg signed [10:0] dy_s;
					reg [10:0] dy_u;
					reg [10:0] height_total;
					reg signed [10:0] offset_top;
					offset_top = flipscreen_spr ? 11'sd0
					                            : $signed({{4{1'b0}}, multi, 4'b0});
					dy_s = ($signed({scan_y[9], scan_y}) - $signed({sy_signed[9], sy_signed}))
					     + offset_top;
					height_total = {7'd0, multi, 4'b0} + 11'd16;  // = 16*(multi+1)
					if (dy_s >= 11'sd0 && dy_s < $signed({1'b0, height_total})) begin
						dy_u = dy_s[10:0];
						tile_idx <= dy_u[6:4];   // 0..multi, NO fy inversion
						// fy_eff row inversion
						if (flipy ^ flipscreen_spr)
							row_in_tile <= 4'd15 - dy_u[3:0];
						else
							row_in_tile <= dy_u[3:0];
						half        <= 1'b0;
						state       <= S_ROM_REQ;
					end else begin
						// Sprite does NOT intersect: skip it ENTIRELY (S_NEXT_SPR).
						// Going through S_NEXT_W, for w_mode sprites the w branch
						// would fire anyway -> PHANTOM DRAW of col2 of a rejected
						// sprite (wasted fetch) = spurious pixels on overlaps +
						// wasted budget. MAME: non-intersecting = nothing drawn.
						state <= S_NEXT_SPR;
					end
				end
			end

			S_ROM_REQ: begin
				// code_y, code_col_extra, code_sel computed BLOCKING to avoid an
				// intra-clock non-blocking dependency (= reading code_y before the non-blocking
				// assignment → OLD value of the previous sprite/iteration).
				begin : compute_and_fetch
					reg [15:0] base_aligned;
					reg        fy_eff;
					reg [15:0] code_y_new;
					reg [15:0] code_col_extra_new;
					reg        half_use;
					reg [3:0]  row_use;
					reg [15:0] code_sel;

					fy_eff = flipy ^ flipscreen_spr;
					base_aligned = code_base & ~({13'd0, multi});
					code_y_new = fy_eff
					             ? (base_aligned + ({13'd0, multi} - {12'd0, tile_idx}))
					             : (base_aligned + {12'd0, tile_idx});
					code_col_extra_new = code_y_new - {13'd0, multi} - 16'd1;


					// flipx half-swap: when fx_eff=1 (mirrored sprite), MAME also reverses
					// the order of the 2 halves of the tile (besides the pixel-in-byte flip
					// already done by bit_x). Without this XOR, the mirrored sprite shows the
					// left quadrant where the right one should be (and vice versa).
					half_use = (~half ^ fx_eff) ^ osd_spr_half_eff_inv;
					row_use  = osd_spr_row_inv ? (4'd15 - row_in_tile) : row_in_tile;
					code_sel = (w_iter ^ osd_spr_w_code_swap) ? code_col_extra_new : code_y_new;

					// ADJACENT HALVES: main = {code, ROW, HALF} (halves A/B
					// adjacent in DDR = fetch of B is an arbiter cache hit). The download applies
					// the same rotation (spr_w_s in boogwings_top). P4 stays {code, half, row}
					// (unchanged linear layout).
					if (chip_idx) begin
						rom1_addr <= {2'd0, code_sel, row_use, half_use, 1'b0};
						rom1_req  <= 1'b1;
					end else begin
						rom0_addr <= {2'd0, code_sel, row_use, half_use, 1'b0};
						rom0_req  <= 1'b1;
						// P4 (5th plane) fetch: 1 byte/group, original LINEAR layout.
						rom0_p4_addr <= {3'd0, code_sel, half_use, row_use};
						rom0_p4_req  <= 1'b1;
						p4_ok        <= 1'b0;   // wait for the P4 of THIS group
					end
					rom_ok <= 1'b0;             // wait for the main data of THIS group
				end
				state       <= S_ROM_WAIT;
			end

			S_ROM_WAIT: begin
				rom0_req <= 1'b0;
				rom0_p4_req <= 1'b0;
				rom1_req <= 1'b0;
				// Wait for the LATCHES of both arrivals (main + P4).
				if (rom_ok && (chip_idx || (SPR0_5BPP == 0) || p4_ok) && ~d_busy) begin
					// DISPATCH (cross-sprite prefetch): snapshot of the draw
					// context and IMMEDIATE continuation with the address generation of
					// the next group (B, col2 or first group of the NEXT sprite,
					// via S_NEXT_*/S_POP/S_FIND_ROW/S_ROM_REQ): its DDR round-trip
					// runs under the 8 px just launched. This general case also
					// covers the prefetch within a sprite.
					rom_lat <= rom_data_cur;
					p4_lat  <= rom0_p4_data;
					d_sx    <= sx_col;
					d_half  <= half;
					d_chip  <= chip_idx;
					d_flipx <= flipx;
					d_color <= color;
					d_pix   <= 3'd0;
					d_busy  <= 1'b1;
					if (~half) begin
						half  <= 1'b1;
						state <= S_ROM_REQ;    // fetch B under the draw of A
					end else begin
						state <= S_NEXT_HALF;  // col2/next sprite under the draw of B
					end
				end
			end

			S_NEXT_HALF: begin
				// 16 columns drawn for the current row of the sprite. Go to w_mode or next sprite.
				half <= 1'b0;
				state <= S_NEXT_W;
			end

			S_NEXT_W: begin
				if (w_mode && !w_iter) begin
					w_iter <= 1'b1;
					// MAME decospr.cpp:351 → 2nd block at (x+16) for flipscreen_spr=1,
					// (x-16) for flipscreen_spr=0.
					// OSD w_swap_pos: swaps 1st/2nd block. OSD w_offset: extra signed offset.
					if (osd_spr_w_swap_pos)
						sx_col <= sx_anchor;
					else
						sx_col <= sx_anchor
						          + (flipscreen_spr ? 10'sd16 : -10'sd16)
						          + ({{6{osd_spr_w_offset[3]}}, osd_spr_w_offset, 4'd0});
					half   <= 1'b0;
					// cross-sprite prefetch: the col2 request starts from
					// S_ROM_REQ NOW, while the draw of B of col1 runs in parallel.
					state  <= S_ROM_REQ;
				end else begin
					state <= S_NEXT_SPR;
				end
			end

			// ASCENDING scan. SHADOW SCAN: the order is guaranteed
			// by the FIFO (push in scan order); here the FSM simply goes back
			// to pop the next match.
			S_NEXT_SPR: begin
				state <= S_POP;
			end

			S_FLUSH: begin
				// Line close: waits for the end of the draw engine (8 atomic px),
				// never line-buffer writes after done_ok/swap. 1 cycle if idle.
				if (~d_busy) state <= S_DONE;
			end

			S_DONE: begin
				// Line complete: done_ok (wire) queues the buffer in this
				// same cycle. Back to IDLE: with free-run the next line can
				// start immediately.
				state <= S_IDLE;
			end

			default: state <= S_IDLE;
		endcase
	end
end

endmodule
