//
// deco16ic_jt.sv — DECO16IC tilemap engine in Jotego BAC06 style.
//
// Architectural reference: jtcop_bac06.v (Jotego, jtcores "cop" core)
//
// Differences from BAC06 (RoboCop / 1 chip = 1 layer):
//   - DECO16IC has 2 layers, pf1 + pf2, in the same chip
//   - separate pf1 and pf2 VRAM (8KB each)
//   - 1 shared set of ctrl registers (8 words)
//   - separate pf1+pf2 rowscroll RAM
//
// Rendering style (as in Jotego's cores):
//   - Scanline-based with 2×320 pixel line buffers (1 for pf1, 1 for pf2)
//   - On HBlank rising: scan the tiles of the next line
//   - For each tile: one 32-bit ROM fetch, shift right to extract 8 pixels,
//     write 8 pixels to the line buffer
//   - 16x16: 2 fetches per tile (half=0 → bit5=1, half=1 → bit5=0)
//   - Output pixel: read linebuf @ render_x
//
// Pixel extraction (Jotego no-hflip):
//   draw_pxl = { rom_data[16], rom_data[24], rom_data[0], rom_data[8] }
//   draw_data >>= 1 for each pixel
//
// Color combine: 8-bit { tile_pal[3:0], draw_pxl[3:0] }
//

module deco16ic_jt
#(
	parameter [1:0] BANK1_MODE = 2'd0,
	parameter [1:0] BANK2_MODE = 2'd0,
	parameter [4:0] PF1_COL_BANK = 5'd0,
	parameter [3:0] PF1_COL_MASK = 4'hF,
	parameter [4:0] PF2_COL_BANK = 5'd0,
	parameter [3:0] PF2_COL_MASK = 4'hF,
	parameter integer PF1_TILE_SIZE = 16,
	parameter integer PF2_TILE_SIZE = 16,
	parameter [2:0] PF1_REGION_ID = 3'd1,
	parameter [2:0] PF2_REGION_ID = 3'd1,
	// 5th plane support for pf2 (BoogieWings BG1 5bpp via mbd-02 = TILES2_HI).
	// When 1: uses the pf2_p4_* port to fetch the 5th plane in parallel.
	parameter integer PF2_HAS_5BPP = 0,
	parameter [2:0] PF2_REGION_ID_P4 = 3'd4,
	// Savestate SS_IDX per block (passed from the top, unique per instance)
	parameter integer SS_VRAM_PF1_IDX = 0,
	parameter integer SS_VRAM_PF2_IDX = 0,
	parameter integer SS_RS_PF1_IDX   = 0,
	parameter integer SS_RS_PF2_IDX   = 0,
	parameter integer SS_CTRL_IDX     = 0
)
(
	input  wire        clk,
	input  wire        reset,

	// CPU bus (16-bit)
	input  wire [15:0] cpu_addr,
	input  wire        cpu_cs,
	input  wire        cpu_rd,
	input  wire        cpu_wr,
	input  wire [15:0] cpu_wdata,
	input  wire  [1:0] cpu_dsn,
	output wire [15:0] cpu_rdata,

	// Render timing (from the top)
	input  wire  [9:0] render_x,    // 0..319 in active, beyond in blanking
	input  wire  [9:0] render_y,    // 0..271 frame
	input  wire        hblank_in,   // active during hblank
	input  wire        vblank_in,
	input  wire        ce_pix,

	output wire  [3:0] pf1_pix,
	output wire  [4:0] pf2_pix,    // 5-bit for 5bpp support (BoogieWings BG1)
	output wire  [4:0] pf1_col,
	output wire  [4:0] pf2_col,
	output wire        pf1_opaque,
	output wire        pf2_opaque,

	// Global flip screen (MAME boogwing.cpp:419-425: pf_control_r(0) bit 7).
	// Taken from chip 0 only (chip1 has its own, but MAME uses only chip0).
	output wire        flip_screen,

	// Tile ROM fetch (1 client per layer)
	output wire [23:0] pf1_rom_addr,
	output wire [2:0]  pf1_region_id,
	output wire        pf1_rom_req,
	input  wire [31:0] pf1_rom_data,
	input  wire        pf1_rom_valid,
	output wire [23:0] pf2_rom_addr,
	output wire [2:0]  pf2_region_id,
	output wire        pf2_rom_req,
	input  wire [31:0] pf2_rom_data,
	input  wire        pf2_rom_valid,

	// Plane 4 dedicated channel (PF2_HAS_5BPP only). Raw byte, no permutation.
	// pf2_p4_req toggles separately from pf2_rom_req and bypasses the 4-plane
	// path (passing p4 through the tile permutation fragments its bit pattern).
	output wire        pf2_p4_req,
	input  wire  [7:0] pf2_p4_data,
	input  wire        pf2_p4_valid,

	// === GFX runtime permutations (unused: the decode is hardcoded) ===
	input  wire [4:0]  osd_tile_decode_mode,
	input  wire        osd_pixel_bit_msb,
	input  wire        osd_plane_rev32,
	input  wire        osd_nibble_swap,
	input  wire        osd_byte_swap_ab,
	input  wire        osd_xhalf_inv,
	input  wire        osd_tile_hi_rev,
	input  wire [1:0]  osd_vram_swizzle,

	// === Plane 4 (BG1 5bpp) runtime permutations ===
	// They act on sc2_p4_latch (raw p4 byte from the bridge), before the
	// bit indexing. Only with PF2_HAS_5BPP=1.
	input  wire [1:0]  osd_p4_byte_pos,   // 00=[7:0] 01=[15:8] 10=[23:16] 11=[31:24]
	input  wire        osd_p4_brev8,      // bit-reverse of the selected p4 byte
	input  wire        osd_p4_bit_shift,  // 1 bit-position shift (pix_y offset test)

	// === Savestate ssbus (4 slots: vram pf1/pf2, rs pf1/pf2). Internal adaptors: they take
	// over the CPU port (write) and, during SS (game paused), the SCAN port for reads.
	// Transparent when SS is idle. control[8] is saved directly via ss_ctrl (like TC0100SCN ctrl[]). ===
	ssbus_if.slave     ss_vram_pf1,
	ssbus_if.slave     ss_vram_pf2,
	ssbus_if.slave     ss_rs_pf1,
	ssbus_if.slave     ss_rs_pf2,
	ssbus_if.slave     ss_ctrl
	,
	// POCKET: port A of the pf1/pf2 VRAM = CPU write
	// + CPU readback, replacing shadow mirror copies in the top (same
	// content by construction: same writes). Address/we/data come from the
	// top (address from the mirror's savestate adapter, writes from the CPU only).
	input  wire [11:0] ext1_addr,
	input  wire        ext1_we_lo,
	input  wire        ext1_we_hi,
	input  wire [15:0] ext1_wdata,
	output wire [15:0] pa1_q,
	input  wire [11:0] ext2_addr,
	input  wire        ext2_we_lo,
	input  wire        ext2_we_hi,
	input  wire [15:0] ext2_wdata,
	output wire [15:0] pa2_q
);

assign pf1_region_id = PF1_REGION_ID;
// pf2 region_id: always PF2_REGION_ID (p4 has its own channel, pf2_p4_*).
assign pf2_region_id = PF2_REGION_ID;

// p4 toggle req (dedicated channel, separate from pf2_rom_req)
reg sc2_p4_req_tgl;
assign pf2_p4_req = sc2_p4_req_tgl;

// Forward declarations for ModelSim 10.5b (Quartus accepts them inline, ModelSim does not).
// State is 5 bits wide to support the per-half colscroll lookup (MAME 1:1).
reg [4:0] sc1_state;
reg [4:0] sc2_state;
wire [31:0] rom_perm_fresh     = pf1_rom_data;
wire [31:0] rom_perm_fresh_pf2 = pf2_rom_data;

// =====================================================================
// VRAM + Ctrl regs (CPU side)
// =====================================================================
wire is_pf1_data = cpu_cs & (cpu_addr[15:13] == 3'b010);
wire is_pf2_data = cpu_cs & (cpu_addr[15:13] == 3'b011);
wire is_pf1_rs   = cpu_cs & (cpu_addr[15:12] == 4'h8);
wire is_pf2_rs   = cpu_cs & (cpu_addr[15:12] == 4'hA);
wire is_ctrl     = cpu_cs & (cpu_addr[15:4]  == 12'd0);

wire [10:0] cpu_rs_idx = cpu_addr[11:1];

// no_rw_check: on read-during-write to the SAME cell the M10K returns
// "don't care". Without the attribute Quartus infers NEW_DATA behaviour, which
// can glitch (= transient X). With the CPU writing and the scan reading in
// parallel (separate ports but the same cell), a glitch on one scanline =
// flicker artifact. no_rw_check says "no need to guarantee NEW_DATA, old is fine"
// → stable output = no artifacts.
(* ramstyle = "M10K", no_rw_check *) reg [7:0] pf1_vram_lo [0:4095];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] pf1_vram_hi [0:4095];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] pf2_vram_lo [0:4095];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] pf2_vram_hi [0:4095];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] pf1_rs_lo [0:2047];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] pf1_rs_hi [0:2047];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] pf2_rs_lo [0:2047];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] pf2_rs_hi [0:2047];
// Explicit BRAM init (without it: garbage at boot)
integer ii_vr;
initial begin
	for (ii_vr = 0; ii_vr < 4096; ii_vr = ii_vr + 1) begin
		pf1_vram_lo[ii_vr] = 8'd0; pf1_vram_hi[ii_vr] = 8'd0;
		pf2_vram_lo[ii_vr] = 8'd0; pf2_vram_hi[ii_vr] = 8'd0;
	end
	for (ii_vr = 0; ii_vr < 2048; ii_vr = ii_vr + 1) begin
		pf1_rs_lo[ii_vr] = 8'd0; pf1_rs_hi[ii_vr] = 8'd0;
		pf2_rs_lo[ii_vr] = 8'd0; pf2_rs_hi[ii_vr] = 8'd0;
	end
end

wire pf1rs_we_lo = is_pf1_rs & cpu_wr & ~cpu_dsn[0];
wire pf1rs_we_hi = is_pf1_rs & cpu_wr & ~cpu_dsn[1];
wire pf2rs_we_lo = is_pf2_rs & cpu_wr & ~cpu_dsn[0];
wire pf2rs_we_hi = is_pf2_rs & cpu_wr & ~cpu_dsn[1];

// Savestate: during SS (game paused) the CPU write port is redirected to the SS bus.
// addr/data from ssbus, we = ssbus.write (writes lo/hi together = 16 bits/word). When SS
// is idle: transparent (CPU port: ext*_* for the VRAM, cpu_rs_idx/cpu_wdata for rowscroll).
wire ssv1 = ss_vram_pf1.access(SS_VRAM_PF1_IDX);
wire ssv2 = ss_vram_pf2.access(SS_VRAM_PF2_IDX);
wire ssr1 = ss_rs_pf1.access(SS_RS_PF1_IDX);
wire ssr2 = ss_rs_pf2.access(SS_RS_PF2_IDX);

wire [11:0] pf1v_waddr = ssv1 ? ss_vram_pf1.addr[11:0] : ext1_addr;
wire [11:0] pf2v_waddr = ssv2 ? ss_vram_pf2.addr[11:0] : ext2_addr;
wire [10:0] pf1r_waddr = ssr1 ? ss_rs_pf1.addr[10:0]   : cpu_rs_idx;
wire [10:0] pf2r_waddr = ssr2 ? ss_rs_pf2.addr[10:0]   : cpu_rs_idx;
wire [15:0] pf1v_wdata = ssv1 ? ss_vram_pf1.data[15:0] : ext1_wdata;
wire [15:0] pf2v_wdata = ssv2 ? ss_vram_pf2.data[15:0] : ext2_wdata;
wire [15:0] pf1r_wdata = ssr1 ? ss_rs_pf1.data[15:0]   : cpu_wdata;
wire [15:0] pf2r_wdata = ssr2 ? ss_rs_pf2.data[15:0]   : cpu_wdata;
wire pf1v_we_lo = ssv1 ? ss_vram_pf1.write : ext1_we_lo;
wire pf1v_we_hi = ssv1 ? ss_vram_pf1.write : ext1_we_hi;
wire pf2v_we_lo = ssv2 ? ss_vram_pf2.write : ext2_we_lo;
wire pf2v_we_hi = ssv2 ? ss_vram_pf2.write : ext2_we_hi;
wire pf1r_we_lo = ssr1 ? ss_rs_pf1.write : pf1rs_we_lo;
wire pf1r_we_hi = ssr1 ? ss_rs_pf1.write : pf1rs_we_hi;
wire pf2r_we_lo = ssr2 ? ss_rs_pf2.write : pf2rs_we_lo;
wire pf2r_we_hi = ssr2 ? ss_rs_pf2.write : pf2rs_we_hi;

// port A = write + readback at the same address, IN THE SAME always block: this way
// Quartus infers a true dual-port RAM (A read/write, B renderer read) instead of
// duplicating it. The read sees the data from before the write, as with separate
// blocks.
reg [7:0] pa1_lo, pa1_hi, pa2_lo, pa2_hi;
always @(posedge clk) begin if (pf1v_we_lo) pf1_vram_lo[pf1v_waddr] <= pf1v_wdata[ 7:0]; pa1_lo <= pf1_vram_lo[pf1v_waddr]; end
always @(posedge clk) begin if (pf1v_we_hi) pf1_vram_hi[pf1v_waddr] <= pf1v_wdata[15:8]; pa1_hi <= pf1_vram_hi[pf1v_waddr]; end
always @(posedge clk) begin if (pf2v_we_lo) pf2_vram_lo[pf2v_waddr] <= pf2v_wdata[ 7:0]; pa2_lo <= pf2_vram_lo[pf2v_waddr]; end
always @(posedge clk) begin if (pf2v_we_hi) pf2_vram_hi[pf2v_waddr] <= pf2v_wdata[15:8]; pa2_hi <= pf2_vram_hi[pf2v_waddr]; end
assign pa1_q = {pa1_hi, pa1_lo};
assign pa2_q = {pa2_hi, pa2_lo};

always @(posedge clk) if (pf1r_we_lo)  pf1_rs_lo[pf1r_waddr] <= pf1r_wdata[ 7:0];
always @(posedge clk) if (pf1r_we_hi)  pf1_rs_hi[pf1r_waddr] <= pf1r_wdata[15:8];
always @(posedge clk) if (pf2r_we_lo)  pf2_rs_lo[pf2r_waddr] <= pf2r_wdata[ 7:0];
always @(posedge clk) if (pf2r_we_hi)  pf2_rs_hi[pf2r_waddr] <= pf2r_wdata[15:8];

// SS setup + read response for the 4 RAMs. The READ reuses the SCAN port (sc*_vram_idx /
// sc*_rs lookup), taken over: during SS the renderer is paused. read_delay 1 ck (BRAM latency).
reg ssv1_rd_d, ssv2_rd_d, ssr1_rd_d, ssr2_rd_d;
always @(posedge clk) begin
	ss_vram_pf1.setup(SS_VRAM_PF1_IDX, 4096, 1);
	ss_vram_pf2.setup(SS_VRAM_PF2_IDX, 4096, 1);
	ss_rs_pf1.setup  (SS_RS_PF1_IDX,   2048, 1);
	ss_rs_pf2.setup  (SS_RS_PF2_IDX,   2048, 1);

	ssv1_rd_d <= ssv1 & ss_vram_pf1.read;
	ssv2_rd_d <= ssv2 & ss_vram_pf2.read;
	ssr1_rd_d <= ssr1 & ss_rs_pf1.read;
	ssr2_rd_d <= ssr2 & ss_rs_pf2.read;

	if (ssv1 & ss_vram_pf1.write) ss_vram_pf1.write_ack(SS_VRAM_PF1_IDX);
	if (ssv2 & ss_vram_pf2.write) ss_vram_pf2.write_ack(SS_VRAM_PF2_IDX);
	if (ssr1 & ss_rs_pf1.write)   ss_rs_pf1.write_ack(SS_RS_PF1_IDX);
	if (ssr2 & ss_rs_pf2.write)   ss_rs_pf2.write_ack(SS_RS_PF2_IDX);

	if (ssv1_rd_d) ss_vram_pf1.read_response(SS_VRAM_PF1_IDX, {48'b0, sc1_vram_rd});
	if (ssv2_rd_d) ss_vram_pf2.read_response(SS_VRAM_PF2_IDX, {48'b0, sc2_vram_rd});
	if (ssr1_rd_d) ss_rs_pf1.read_response(SS_RS_PF1_IDX, {48'b0, pf1_rs_ss_rd});
	if (ssr2_rd_d) ss_rs_pf2.read_response(SS_RS_PF2_IDX, {48'b0, pf2_rs_ss_rd});
end

// Ctrl regs
reg [15:0] pf12_control [0:7];
wire [2:0] ctrl_idx = cpu_addr[3:1];

// Control[8] regs: CPU write + direct savestate access (8 words, TC0100SCN ctrl[] pattern).
always @(posedge clk) begin
	ss_ctrl.setup(SS_CTRL_IDX, 8, 1);
	if (ss_ctrl.access(SS_CTRL_IDX)) begin
		if (ss_ctrl.write) begin
			pf12_control[ss_ctrl.addr[2:0]] <= ss_ctrl.data[15:0];
			ss_ctrl.write_ack(SS_CTRL_IDX);
		end else if (ss_ctrl.read) begin
			ss_ctrl.read_response(SS_CTRL_IDX, {48'b0, pf12_control[ss_ctrl.addr[2:0]]});
		end
	end else if (is_ctrl & cpu_wr) begin
		if (~cpu_dsn[0]) pf12_control[ctrl_idx][ 7:0] <= cpu_wdata[ 7:0];
		if (~cpu_dsn[1]) pf12_control[ctrl_idx][15:8] <= cpu_wdata[15:8];
	end
end

// Global flip screen (MAME boogwing.cpp:419-425):
//   flip = m_deco_tilegen[0]->pf_control_r(0); flip_screen = BIT(flip,7);
assign flip_screen = pf12_control[0][7];

// MAME deco16ic.cpp:899-900 (the code, NOT the header comment, which is inverted):
//   PF1 scroll = ctrl[1] (X), ctrl[2] (Y)
//   PF2 scroll = ctrl[3] (X), ctrl[4] (Y)
wire [15:0] pf1_scroll_x = pf12_control[1];
wire [15:0] pf1_scroll_y = pf12_control[2];
wire [15:0] pf2_scroll_x = pf12_control[3];
wire [15:0] pf2_scroll_y = pf12_control[4];

// Rowscroll enable + style (MAME deco16ic.cpp header, lines 94-130)
//   pf12_control[5] (word 0xa):
//     bit 15    = pf1 enable
//     bit 14:11 = pf1 rowscroll style
//     bit 10:8  = pf1 colscroll style
//     bit 7     = pf2 enable
//     bit 6:3   = pf2 rowscroll style
//     bit 2:0   = pf2 colscroll style
//   pf12_control[6] (word 0xc):
//     bit 15 = pf1 8x8 tile
//     bit 14 = pf1 rowscroll enabled
//     bit 13 = pf1 colscroll enabled
//     bit 7  = pf2 8x8 tile
//     bit 6  = pf2 rowscroll enabled
//     bit 5  = pf2 colscroll enabled
// Rowscroll enable = BIT 6 ALONE (custom_tilemap_draw MAME deco16ic.cpp:481), NOT
// (control1 & 0x60)==0x40: that condition belongs to the STANDARD tilemap path (deco16ic.cpp:758),
// which only covers row-ONLY; with 0x60 (row+col SIMULTANEOUS, e.g. the Data East logo dissolve)
// MAME switches to the custom renderer (:847-850), which applies bit6 and bit5 INDEPENDENTLY, together.
// Testing ==2'b10 would kill rowscroll exactly in the 0x60 case -> vertical bands without the
// fine stripes. In the 0x40/0x20/0x00 cases bit 6 alone gives the same result.
// Style: ctrl[0] per pf_update (for pf1 = ctrl[5] & 0xff = bits 7:0).
//        MAME line 761: (control0 >> 3) & 0xf -> bits 6:3 for the pf1 row style.
//        For pf2 = ctrl[5] >> 8 = bits 15:8, then (>> 3) & 0xf -> bits 14:11.
wire [3:0] pf1_rs_style = pf12_control[5][6:3];
wire [3:0] pf2_rs_style = pf12_control[5][14:11];
wire       pf1_rs_en    = pf12_control[6][6];
wire       pf2_rs_en    = pf12_control[6][14];

// COLSCROLL Y-per-column (MAME deco16ic.cpp:492-497, 812):
//   col_type = 8 << (control0 & 7) ∈ {8,16,32,64,128,256,512,1024}
//   col_idx = (src_x & 0x1ff) / col_type
//   col_offset = rowscroll_ptr[0x200 + col_idx]   // 16-bit Y offset
//   veff_eff = veff + col_offset
// MAME code (NOT the header comment, which is inverted):
//   control0 PF1 = ctrl[5] & 0xff  → col_style = bit 2:0 = ctrl[5][2:0]
//   control0 PF2 = ctrl[5] >> 8    → col_style = bit 2:0 = ctrl[5][10:8]
//   control1 PF1 = ctrl[6] & 0xff  → col_en = bit 5 = ctrl[6][5]
//   control1 PF2 = ctrl[6] >> 8    → col_en = bit 5 = ctrl[6][13]
wire [2:0] pf1_cs_style = pf12_control[5][2:0];
wire [2:0] pf2_cs_style = pf12_control[5][10:8];
wire       pf1_cs_en    = pf12_control[6][5];
wire       pf2_cs_en    = pf12_control[6][13];

// PLAYFIELD DISABLE (MAME deco16ic.cpp:465: if(!BIT(control0,7)) return;).
// The playfield is drawn ONLY if control0 bit7 == 1. control0 pf1 = ctrl[5][7:0] -> bit7=[7];
// control0 pf2 = ctrl[5][15:8] -> bit7=[15]. If 0 -> transparent playfield (opaque=0).
wire       pf1_enable   = pf12_control[5][7];
wire       pf2_enable   = pf12_control[5][15];
function [3:0] cs_col_shift(input [2:0] style);
	case (style)
		3'd0: cs_col_shift = 4'd3;   // col_type=8   → idx = x/8
		3'd1: cs_col_shift = 4'd4;   // col_type=16
		3'd2: cs_col_shift = 4'd5;   // col_type=32
		3'd3: cs_col_shift = 4'd6;   // col_type=64
		3'd4: cs_col_shift = 4'd7;   // col_type=128
		3'd5: cs_col_shift = 4'd8;   // col_type=256
		3'd6: cs_col_shift = 4'd9;   // col_type=512
		3'd7: cs_col_shift = 4'd10;  // col_type=1024
		default: cs_col_shift = 4'd3;
	endcase
endfunction
wire [3:0] pf1_cs_shift = cs_col_shift(pf1_cs_style);
wire [3:0] pf2_cs_shift = cs_col_shift(pf2_cs_style);

// Rowscroll lookup: index = current_pixel_y / row_type.
// Base: render_y + 1 + scroll_y (= y of the next scanline); see the lookahead below.
// For 8x8 text MAME halves numrows (line 798); equivalent to >> 1 on the idx.
// Forward decl: pf*_latched_render_y are driven by the go_latch logic below.
// ModelSim 10.5b does not accept use before declaration, so they are declared here.
reg [9:0] pf1_latched_render_y;
reg [9:0] pf2_latched_render_y;
reg       pf1_go_latch, pf2_go_latch;
// Rowscroll index: lookahead +2. With +1 the transition between the 2 speeds is 1 line off,
// with +0 it is 2 lines off. +2 cancels the offset (the rowscroll value takes 1 ck more to fetch
// than the tile, so it must look 1 line beyond the +1 of the position). sc1_veff/sc2_veff are
// NOT affected (positions unchanged).
wire [9:0] pf1_veff_rs = pf1_latched_render_y + 10'd2 + pf1_scroll_y[9:0];
wire [9:0] pf2_veff_rs = pf2_latched_render_y + 10'd2 + pf2_scroll_y[9:0];
// 16x16: veff MASKED to [8:0] (= & height_mask 511, MAME deco16ic.cpp:477/:534) BEFORE
// the shift. Without the mask, with a large scroll_y (Data East logo dissolve: bit9=1) the index
// leaves the rowscroll table (0x000-0x1FF) and reads the COLSCROLL/empty area (0x200+) ->
// ~constant X offset on every line = no fine stripes, only the colscroll vertical bands
// remain. Zero-cost bit-select (same approach as cs_hnm below).
wire [10:0] pf1_rs_idx_pre = (PF1_TILE_SIZE == 8) ? {1'b0, pf1_veff_rs[9:1]} : {2'b00, pf1_veff_rs[8:0]};
wire [10:0] pf2_rs_idx_pre = (PF2_TILE_SIZE == 8) ? {1'b0, pf2_veff_rs[9:1]} : {2'b00, pf2_veff_rs[8:0]};
// Division by row_type via shift (row_type is always a power of 2).
wire [3:0] pf1_rs_shift = (pf1_rs_style <= 4'd8) ? pf1_rs_style : 4'd0;
wire [3:0] pf2_rs_shift = (pf2_rs_style <= 4'd8) ? pf2_rs_style : 4'd0;
wire [10:0] pf1_rs_idx = pf1_rs_idx_pre >> pf1_rs_shift;
wire [10:0] pf2_rs_idx = pf2_rs_idx_pre >> pf2_rs_shift;

// COLSCROLL idx (per-half lookup: MAME's 1:1 per pixel collapsed to per-half because
// cs_off is constant over 8 consecutive px for col_type≥8).
// idx = 0x200 + (src_x >> cs_shift) for half 0, idx = 0x200 + ((src_x+8) >> cs_shift) h1.
// Columns during scroll (MAME deco16ic.cpp:493 col_idx from src_x = REAL pixel):
// src_x must clear the sub-tile offset scroll_x[3:0] (16x16) or [2:0] (8x8). Since
// sc*_hn = scroll_x + N*tile (N*16 or N*8 do not touch the low bits), subtracting sub ==
// MASKING the low bits of sc*_hn -> ZERO-COST bit-select (no subtractor, no change
// to fit/timing/DDR accesses).
wire [8:0] pf1_cs_hnm = (PF1_TILE_SIZE == 8) ? {sc1_hn[8:3], 3'b0} : {sc1_hn[8:4], 4'b0};
wire [8:0] pf2_cs_hnm = (PF2_TILE_SIZE == 8) ? {sc2_hn[8:3], 3'b0} : {sc2_hn[8:4], 4'b0};
wire [8:0] pf1_cs_off_h0 =  pf1_cs_hnm            >> pf1_cs_shift;
wire [8:0] pf1_cs_off_h1 = (pf1_cs_hnm + 9'd8)    >> pf1_cs_shift;
wire [8:0] pf2_cs_off_h0 =  pf2_cs_hnm            >> pf2_cs_shift;
wire [8:0] pf2_cs_off_h1 = (pf2_cs_hnm + 9'd8)    >> pf2_cs_shift;
wire [10:0] pf1_cs_idx_h0 = {2'b01, pf1_cs_off_h0};
wire [10:0] pf1_cs_idx_h1 = {2'b01, pf1_cs_off_h1};
wire [10:0] pf2_cs_idx_h0 = {2'b01, pf2_cs_off_h0};
wire [10:0] pf2_cs_idx_h1 = {2'b01, pf2_cs_off_h1};

// Mux read 3-way: CPU rd > scan colscroll h0/h1 > rowscroll (default).
wire [10:0] pf1_rs_read_idx = (is_pf1_rs & cpu_rd)        ? cpu_rs_idx :
                              (sc1_state == SC_CS_R)      ? pf1_cs_idx_h0 :
                              (sc1_state == SC_CS_R2)     ? pf1_cs_idx_h1 :
                                                            pf1_rs_idx;
wire [10:0] pf2_rs_read_idx = (is_pf2_rs & cpu_rd)        ? cpu_rs_idx :
                              (sc2_state == SC_CS_R)      ? pf2_cs_idx_h0 :
                              (sc2_state == SC_CS_R2)     ? pf2_cs_idx_h1 :
                                                            pf2_rs_idx;
reg [7:0] pf1_rs_lo_r, pf1_rs_hi_r, pf2_rs_lo_r, pf2_rs_hi_r;
// RS read addr redirected to ssbus.addr during SS (renderer paused).
wire [10:0] pf1_rs_raddr = ssr1 ? ss_rs_pf1.addr[10:0] : pf1_rs_read_idx;
wire [10:0] pf2_rs_raddr = ssr2 ? ss_rs_pf2.addr[10:0] : pf2_rs_read_idx;
// 1 always per array → M10K safe
always @(posedge clk) pf1_rs_lo_r <= pf1_rs_lo[pf1_rs_raddr];
always @(posedge clk) pf1_rs_hi_r <= pf1_rs_hi[pf1_rs_raddr];
always @(posedge clk) pf2_rs_lo_r <= pf2_rs_lo[pf2_rs_raddr];
always @(posedge clk) pf2_rs_hi_r <= pf2_rs_hi[pf2_rs_raddr];
wire [15:0] pf1_rs_value = {pf1_rs_hi_r, pf1_rs_lo_r};
wire [15:0] pf2_rs_value = {pf2_rs_hi_r, pf2_rs_lo_r};
wire [15:0] pf1_rs_ss_rd = {pf1_rs_hi_r, pf1_rs_lo_r};
wire [15:0] pf2_rs_ss_rd = {pf2_rs_hi_r, pf2_rs_lo_r};

wire [7:0] bank1_in = pf12_control[7][7:0];
wire [7:0] bank2_in = pf12_control[7][15:8];

function [14:0] bank_calc(input [1:0] mode, input [7:0] bank);
	reg [14:0] base;
	begin
		base = {bank[6:4], 12'd0};
		case (mode)
			2'd1: bank_calc = base;
			2'd2: bank_calc = base + ((bank[3:0] == 4'hA) ? 15'h0800 : 15'd0);
			default: bank_calc = 15'd0;
		endcase
	end
endfunction

wire [14:0] pf1_bank_off = bank_calc(BANK1_MODE, bank1_in);
wire [14:0] pf2_bank_off = bank_calc(BANK2_MODE, bank2_in);

// Minimal CPU readback: the rs read is shared with the scan mux (above).
reg [15:0] ctrl_rd;
always @(posedge clk) ctrl_rd     <= pf12_control[ctrl_idx];
reg [4:0] is_d;
always @(posedge clk) is_d <= {is_pf1_data, is_pf2_data, is_pf1_rs, is_pf2_rs, is_ctrl};

assign cpu_rdata = is_d[2] ? {pf1_rs_hi_r, pf1_rs_lo_r} :
                   is_d[1] ? {pf2_rs_hi_r, pf2_rs_lo_r} :
                   is_d[0] ? ctrl_rd                    :
                             16'h0000;

// =====================================================================
// HBlank rising detection — start the scan of the next line
// =====================================================================
reg hbl_d;
always @(posedge clk) hbl_d <= hblank_in;
wire hbl_rise = hblank_in & ~hbl_d;   // start of HBlank = good time to scan

// go_latch: if hbl_rise arrives while the FSM is still scanning (not IDLE),
// the event would be lost → line not scanned → linebuf with old data
// = GARBAGE. It is latched until the FSM can consume it in SC_IDLE.
// pf*_go_latch / pf*_latched_render_y are declared above (forward use).

// FSM-side handshake (sc1_state, sc2_state, SC_IDLE):
// pf1: latch on hbl_rise, cleared when the FSM consumes it in SC_IDLE.
// The latch logic is next to each FSM (below).

// =====================================================================
// SCANLINE SCAN pf1 (Jotego-style)
// =====================================================================
// At the start of HBlank of line N: scan the tiles of line N+1.
// veff = (render_y + 1) + scroll_y
// hn   = scroll_x  (= initial scroll for the line)
// For each tile: read VRAM, fetch ROM, write the pf1 line buffer.
// Loop until 320 pixels are filled (= ~20 16x16 tiles or ~40 8x8 tiles).

// 5-bit state (to support per-half colscroll + VRAM re-fetch for half 1).
// MAME 1:1: colscroll lookup PER PIXEL (in practice per HALF of 8 px when col_type≥8).
// Sequence per 16x16 tile:
//   IDLE → CS_R[h0] → CS_WT → VRAM_R → VRAM_WT/WT2 → ROM_REQ → ROM_TRIG → ROM_WT
//        → DRAW_LO (8 px) → CS_R2[h1] → CS_WT2 → VRAM_R [re-fetch] → ROM_REQ2 → DRAW_HI
//        → next tile (back to CS_R)
localparam [4:0]
	SC_IDLE    = 5'd0,
	SC_CS_R    = 5'd14,   // colscroll RAM lookup half 0 (cols 0..7)
	SC_CS_WT   = 5'd15,   // colscroll wait + latch h0
	SC_VRAM_R  = 5'd1,
	SC_VRAM_WT = 5'd2,
	SC_VRAM_WT2= 5'd11,
	SC_ROM_REQ = 5'd3,
	SC_ROM_TRIG= 5'd4,
	SC_ROM_WT  = 5'd5,
	SC_DRAW_LO = 5'd6,
	SC_CS_R2   = 5'd16,   // colscroll lookup half 1 (cols 8..15)
	SC_CS_WT2  = 5'd17,   // colscroll wait + latch h1
	SC_VRAM_R_H1  = 5'd18, // re-fetch VRAM for half 1 (cs h1 ≠ cs h0 → different tile)
	SC_VRAM_WT_H1 = 5'd19,
	SC_VRAM_WT2_H1= 5'd20,
	SC_ROM_LOAD_H1= 5'd21, // sample VRAM h1, update tile_code, go to SC_ROM_REQ2
	SC_ROM_REQ2= 5'd7,
	SC_ROM_TRIG2=5'd8,
	SC_ROM_WT2 = 5'd9,
	SC_DRAW_HI = 5'd10,
	SC_P4_TRIG = 5'd12,
	SC_P4_WT   = 5'd13;

// sc1_state is declared at the top (ModelSim forward decl)
reg [9:0]  sc1_veff;       // effective y of the line being scanned
reg [9:0]  sc1_hn;         // current x
reg [5:0]  sc1_tile;       // tile counter 0..40
reg [11:0] sc1_vram_idx;
reg [14:0] sc1_tile_code;
reg [3:0]  sc1_tile_pal;
reg        sc1_rom_req_tgl;
reg [31:0] sc1_rom_latch;
reg [3:0]  sc1_pix_cnt;
reg [8:0]  sc1_buf_waddr;  // 0..319 line buffer write addr
reg        sc1_buf_we;
reg [7:0]  sc1_buf_wdata;  // {pal[3:0], pen[3:0]}
reg        sc1_half;       // 16x16 second half

// go_latch pf1: latches hbl_rise while the FSM is busy, consumed in SC_IDLE.
always @(posedge clk) begin
	if (reset) begin
		pf1_go_latch <= 1'b0;
		pf1_latched_render_y <= 10'd0;
	end else begin
		if (hbl_rise) begin
			pf1_go_latch <= 1'b1;
			pf1_latched_render_y <= render_y;
		end else if (sc1_state == SC_IDLE && pf1_go_latch) begin
			pf1_go_latch <= 1'b0;
		end
	end
end

// COLSCROLL Y latched per half (h0 = cols 0..7, h1 = cols 8..15). MAME 1:1.
reg [15:0] sc1_cs_value_h0;
reg [15:0] sc1_cs_value_h1;
// Current half mux via sc1_half_logical (= 0 for cols 0..7, 1 for cols 8..15)
wire [15:0] sc1_cs_value_cur = sc1_half_logical ? sc1_cs_value_h1 : sc1_cs_value_h0;
wire [9:0]  sc1_cs_off = pf1_cs_en ? sc1_cs_value_cur[9:0] : 10'd0;
wire [9:0]  sc1_veff_eff = sc1_veff + sc1_cs_off;

// VRAM swizzle hardcoded:
//   8x8 (text)  = Linear        idx = {row[4:0], col[5:0]}
//   16x16 (BG)  = DECO_64x32    idx = {col[5], row[4:0], col[4:0]}
// MAME deco16ic.cpp:245 — TILEMAP_SCAN_ROWS for 8x8, deco16_scan_rows for 16x16.
wire [5:0] sc1_col_w = (PF1_TILE_SIZE == 8) ? {1'b0, sc1_hn[8:3]} : sc1_hn[9:4];
wire [4:0] sc1_row_w = (PF1_TILE_SIZE == 8) ? sc1_veff_eff[7:3]       : sc1_veff_eff[8:4];
wire [11:0] sc1_vram_idx_calc = (PF1_TILE_SIZE == 8) ?
	{1'b0, sc1_row_w, sc1_col_w[5:0]} :
	{1'b0, sc1_col_w[5], sc1_row_w, sc1_col_w[4:0]};

// VRAM read latch
reg [7:0] sc1_vram_rd_lo, sc1_vram_rd_hi;
// Read addr redirected to ssbus.addr during SS (renderer paused) to read the VRAM.
wire [11:0] sc1_vram_raddr = ssv1 ? ss_vram_pf1.addr[11:0] : sc1_vram_idx;
always @(posedge clk) sc1_vram_rd_lo <= pf1_vram_lo[sc1_vram_raddr];
always @(posedge clk) sc1_vram_rd_hi <= pf1_vram_hi[sc1_vram_raddr];
wire [15:0] sc1_vram_rd = {sc1_vram_rd_hi, sc1_vram_rd_lo};

// Pixel-in-tile for Y (= row inside the tile)
wire [3:0] sc1_pix_y = (PF1_TILE_SIZE == 8) ? {1'b0, sc1_veff_eff[2:0]} : sc1_veff_eff[3:0];

// ROM addr from the 15-bit tile_code + pix_y + half:
//   16x16 4bpp: byte_addr = tile_code*64 + half*32 + 2*pix_y (per region)
//                         = {tile_code, half, pix_y[3:0], 1'b0}
//   8x8  4bpp : byte_addr = tile_code*16 + 2*pix_y
//                         = {tile_code, pix_y[2:0], 1'b0}
reg sc1_half_logical;   // 0 = pixel 0..7, 1 = pixel 8..15

// Per-tile flip (MAME deco16ic.cpp:330-341 get_pf1_tile_info):
//   if (vram[15] && ctrl[6][0]) → FLIPX, colour &= 7
//   if (vram[15] && ctrl[6][1]) → FLIPY, colour &= 7
// For pf2 (16x16): ctrl[6][8] and ctrl[6][9].
// The vram[15] bit is latched in SC_ROM_REQ.
wire pf1_flipx_ctrl = pf12_control[6][0];
wire pf1_flipy_ctrl = pf12_control[6][1];
reg  sc1_flipx_r, sc1_flipy_r;

// xhalf hardcoded (osd_xhalf_inv=0): half_base = ~half_logical (pixels 0-7 first).
// tile_hi_rev hardcoded to 0: tile_code passes through.
wire        sc1_half_eff  = ~sc1_half_logical ^ sc1_flipx_r;
wire [3:0]  sc1_pix_y_eff = sc1_flipy_r ?
                            ((PF1_TILE_SIZE == 8) ? (4'd7 - sc1_pix_y) : (4'd15 - sc1_pix_y)) :
                            sc1_pix_y;
wire [14:0] sc1_tile_code_eff = sc1_tile_code;

wire [23:0] sc1_rom_addr_w =
	(PF1_TILE_SIZE == 8) ? {4'd0, sc1_tile_code_eff, sc1_pix_y_eff[2:0], 1'b0} :
	                       {2'd0, sc1_tile_code_eff, sc1_half_eff, sc1_pix_y_eff[3:0], 1'b0};

// Sticky ROM address (latched in the "TRIG" state, so that
// tile_code is valid at the moment of the toggle).
reg [23:0] sc1_rom_addr_r;
always @(posedge clk) begin
	if (sc1_state == SC_ROM_TRIG || sc1_state == SC_ROM_REQ2)
		sc1_rom_addr_r <= sc1_rom_addr_w;
end
assign pf1_rom_addr = sc1_rom_addr_r;
assign pf1_rom_req  = sc1_rom_req_tgl;

// pf1 scan FSM
always @(posedge clk) begin
	if (reset) begin
		sc1_state <= SC_IDLE;
		sc1_rom_req_tgl <= 1'b0;
		sc1_buf_we <= 1'b0;
		sc1_buf_waddr <= 9'd0;
		sc1_flipx_r <= 1'b0;
		sc1_flipy_r <= 1'b0;
	end else begin
		sc1_buf_we <= 1'b0;
		case (sc1_state)
			SC_IDLE: begin
				if (pf1_go_latch) begin
					sc1_veff <= pf1_latched_render_y + 10'd1 + pf1_scroll_y[9:0];
					sc1_hn   <= pf1_scroll_x[9:0] + (pf1_rs_en ? pf1_rs_value[9:0] : 10'd0);
					sc1_tile <= 6'd0;
					// Sub-tile X offset: the scan starts tile-aligned, buf_waddr starts
					// negative (9-bit wrap) to discard the first N pixels of the first
					// tile (= MAME src_x = scroll_x + render_x).
					// 16x16: sub = (scroll_x + rs)[3:0]. 8x8: sub = (scroll_x + rs)[2:0].
					begin : sub_offset_init
						reg [9:0] hn_eff;
						reg [3:0] sub;
						hn_eff = pf1_scroll_x[9:0] + (pf1_rs_en ? pf1_rs_value[9:0] : 10'd0);
						sub    = (PF1_TILE_SIZE == 8) ? {1'b0, hn_eff[2:0]} : hn_eff[3:0];
						// waddr_init = -sub (= 512 - sub mod 512, 9-bit wrap)
						sc1_buf_waddr <= 9'd0 - {5'd0, sub};
					end
					sc1_half_logical <= 1'b0;
					sc1_cs_value_h0 <= 16'd0;
					sc1_cs_value_h1 <= 16'd0;
					sc1_state <= SC_CS_R;
				end
			end
			SC_CS_R: begin
				// Colscroll RAM lookup half 0 (cols 0..7).
				sc1_state <= SC_CS_WT;
			end
			SC_CS_WT: begin
				// Latch colscroll Y for half 0.
				sc1_cs_value_h0 <= pf1_rs_value;
				sc1_state <= SC_VRAM_R;
			end
			SC_VRAM_R: begin
				// VRAM addr set → idx_reg updates at end of ck → BRAM read at end of ck+1
				sc1_vram_idx <= sc1_vram_idx_calc;
				sc1_state <= SC_VRAM_WT;
			end
			SC_VRAM_WT: begin
				// 1 ck wait: at the end of THIS ck `sc1_vram_rd_lo/hi` have
				// captured pf*_vram[new sc1_vram_idx]. In the next ck
				// (SC_VRAM_WT2) the value is stable and can be sampled.
				sc1_state <= SC_VRAM_WT2;
			end
			SC_VRAM_WT2: begin
				// Extra wait to absorb possible read-during-write races
				// (68K CPU writing VRAM while the scan reads the same cell).
				// Cyclone V M10K mixed_port: output stable 2 ck after the addr.
				sc1_state <= SC_ROM_REQ;
			end
			SC_ROM_REQ: begin
				// Update tile_code/pal from VRAM, do NOT toggle req yet
				sc1_tile_code <= {3'd0, sc1_vram_rd[11:0]} + pf1_bank_off;
				// MAME: colour = tile[15:12], if tile[15] && flipctrl colour &= 7
				sc1_tile_pal  <= (sc1_vram_rd[15] && (pf1_flipx_ctrl | pf1_flipy_ctrl)) ?
				                 {1'b0, sc1_vram_rd[14:12]} : sc1_vram_rd[15:12];
				// Latch the per-tile flip (vram[15] && ctrl bit)
				sc1_flipx_r   <= sc1_vram_rd[15] & pf1_flipx_ctrl;
				sc1_flipy_r   <= sc1_vram_rd[15] & pf1_flipy_ctrl;
				sc1_state <= SC_ROM_TRIG;
			end
			SC_ROM_TRIG: begin
				// 1 ck later: tile_code is valid, so sc1_rom_addr_r is
				// updated correctly. Toggle req here.
				sc1_rom_req_tgl <= ~sc1_rom_req_tgl;
				sc1_state <= SC_ROM_WT;
			end
			SC_ROM_WT: begin
				if (pf1_rom_valid) begin
					sc1_rom_latch <= rom_perm_fresh;   // latch the ROM data once
					sc1_pix_cnt <= 4'd7;
					sc1_buf_we <= 1'b1;
					sc1_state <= SC_DRAW_LO;
				end
			end
			SC_DRAW_LO: begin
				// Draw 8 pixels: counter sc1_pix_cnt 7→0, dynamic bit position extraction
				sc1_buf_we <= 1'b1;
				sc1_buf_waddr <= sc1_buf_waddr + 9'd1;
				if (sc1_pix_cnt == 4'd0) begin
					sc1_buf_we <= 1'b0;
					if (PF1_TILE_SIZE == 16 && sc1_half_logical == 1'b0) begin
						// go to half=1: colscroll h1 lookup + VRAM re-fetch
						sc1_half_logical <= 1'b1;
						sc1_state <= SC_CS_R2;
					end else begin
						// tile done
						sc1_half_logical <= 1'b0;
						sc1_tile <= sc1_tile + 6'd1;
						sc1_hn <= sc1_hn + (PF1_TILE_SIZE == 8 ? 10'd8 : 10'd16);
						// Sub-tile offset: waddr can wrap unsigned (= 512-N at the start).
						// Exit ONLY on the tile count (a waddr check would exit early on the wrap).
						if (sc1_tile >= ((PF1_TILE_SIZE == 8) ? 6'd40 : 6'd21)) begin
							sc1_state <= SC_IDLE;
						end else begin
							sc1_state <= SC_CS_R;
						end
					end
				end else begin
					sc1_pix_cnt <= sc1_pix_cnt - 4'd1;
				end
			end
			SC_CS_R2: begin
				// Colscroll RAM lookup half 1 (cols 8..15). MAME 1:1 per-pixel collapsed
				// to per HALF because cs_off is constant over 8 consecutive px with col_type≥8.
				sc1_state <= SC_CS_WT2;
			end
			SC_CS_WT2: begin
				// Latch colscroll Y for half 1, then RE-FETCH VRAM (the tile may differ
				// if cs_off h1 != cs_off h0 → different veff → different Y row).
				sc1_cs_value_h1 <= pf1_rs_value;
				sc1_state <= SC_VRAM_R;
			end
			SC_ROM_REQ2: begin
				sc1_rom_req_tgl <= ~sc1_rom_req_tgl;
				sc1_state <= SC_ROM_WT2;
			end
			SC_ROM_WT2: begin
				if (pf1_rom_valid) begin
					sc1_rom_latch <= rom_perm_fresh;
					sc1_pix_cnt <= 4'd7;
					sc1_buf_we <= 1'b1;
					sc1_state <= SC_DRAW_HI;
				end
			end
			SC_DRAW_HI: begin
				sc1_buf_we <= 1'b1;
				sc1_buf_waddr <= sc1_buf_waddr + 9'd1;
				if (sc1_pix_cnt == 4'd0) begin
					sc1_buf_we <= 1'b0;
					sc1_half_logical <= 1'b0;
					sc1_tile <= sc1_tile + 6'd1;
					sc1_hn <= sc1_hn + 10'd16;
					// SC_DRAW_HI is reached ONLY for PF1_TILE_SIZE=16. Exit only on the tile count.
					if (sc1_tile >= 6'd21) begin
						sc1_state <= SC_IDLE;
					end else begin
						sc1_state <= SC_CS_R;
					end
				end else begin
					sc1_pix_cnt <= sc1_pix_cnt - 4'd1;
				end
			end
			default: sc1_state <= SC_IDLE;
		endcase
	end
end

// Bit pick: LSB-first hardcoded (osd_pixel_bit_msb=0 → bit_pos_base = 7-pix_cnt).
// FLIPX inverts it: flipx ? pix_cnt : 7-pix_cnt.
wire [2:0] bit_pos = sc1_flipx_r ? sc1_pix_cnt[2:0] : (3'd7 - sc1_pix_cnt[2:0]);
wire [3:0] sc1_pen = {
	sc1_rom_latch[5'd24 + {2'd0, bit_pos}],   // plane bit 24 (MSB nibble)
	sc1_rom_latch[5'd16 + {2'd0, bit_pos}],
	sc1_rom_latch[5'd8  + {2'd0, bit_pos}],
	sc1_rom_latch[{2'd0, bit_pos}]            // plane bit 0 (LSB nibble)
};

always @(*) begin
	sc1_buf_wdata = {sc1_tile_pal, sc1_pen};
end

// =====================================================================
// LINE BUFFER pf1 (320 bytes, 8-bit = {pal[3:0], pen[3:0]})
// Double-buffered: write to "back", read from "front", toggle every line
// =====================================================================
(* ramstyle = "M10K", no_rw_check *) reg [7:0] linebuf1_a [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] linebuf1_b [0:511];
integer ii_lb1;
initial for (ii_lb1=0; ii_lb1<512; ii_lb1=ii_lb1+1) begin
	linebuf1_a[ii_lb1] = 8'd0; linebuf1_b[ii_lb1] = 8'd0;
end
// lb_sel SEPARATE for pf1 and pf2: each one flips when its own scan is IDLE.
// A shared "both IDLE" gate would race: the 5bpp PF2 scan is slower because
// of the extra p4 fetch (= doubles the chip0.pf2 bandwidth), so both-IDLE may
// never happen → missed flip → flicker/garbage in the line buffer.
//
// Double-swap race: `hbl_rise` can coincide with `sc_state == IDLE`. In that
// ck an always block doing BOTH `pending <= 1` ("hbl_rise" branch) AND
// `pending <= 0` ("IDLE && pending" branch) lets the LAST non-blocking
// assignment win → pending=0 + swap, and the pending just set by hbl_rise is
// **lost** → the next hbl_rise swaps again while the scan is already writing
// into the displayed buffer → flicker. So the swap condition excludes the
// hbl_rise ck (the pending is set there, the swap happens 1 ck later if IDLE).
reg lb1_sel;   // pf1 linebuf selector
reg lb2_sel;   // pf2 linebuf selector
reg lb1_swap_pending, lb2_swap_pending;
always @(posedge clk) begin
	if (reset) begin
		lb1_sel <= 1'b0;
		lb2_sel <= 1'b0;
		lb1_swap_pending <= 1'b0;
		lb2_swap_pending <= 1'b0;
	end else begin
		if (hbl_rise) begin
			lb1_swap_pending <= 1'b1;
			lb2_swap_pending <= 1'b1;
		end else begin
			if (sc1_state == SC_IDLE && lb1_swap_pending) begin
				lb1_sel <= ~lb1_sel;
				lb1_swap_pending <= 1'b0;
			end
			if (sc2_state == SC_IDLE && lb2_swap_pending) begin
				lb2_sel <= ~lb2_sel;
				lb2_swap_pending <= 1'b0;
			end
		end
	end
end

// Write: 1 always per array → M10K-safe inference. waddr < 320 gating to
// discard out-of-range pixels (sub-tile X offset: the first 0..15 pixels wrap
// to 496..511 unsigned, outside [0..319]).
wire sc1_buf_we_g = sc1_buf_we && (sc1_buf_waddr < 9'd320);
always @(posedge clk) if (sc1_buf_we_g &&  lb1_sel == 1'b0) linebuf1_a[sc1_buf_waddr] <= sc1_buf_wdata;
always @(posedge clk) if (sc1_buf_we_g &&  lb1_sel == 1'b1) linebuf1_b[sc1_buf_waddr] <= sc1_buf_wdata;

// Read: 1 always per array, mux AFTER the read → M10K safe
reg [7:0] lb1_a_rd, lb1_b_rd;
reg       lb1_sel_d;
always @(posedge clk) lb1_a_rd <= linebuf1_a[render_x[8:0]];
always @(posedge clk) lb1_b_rd <= linebuf1_b[render_x[8:0]];
always @(posedge clk) lb1_sel_d <= lb1_sel;
reg [7:0] lb1_rd;
always @(posedge clk) lb1_rd <= (lb1_sel_d == 1'b0) ? lb1_b_rd : lb1_a_rd;

// =====================================================================
// SAME for pf2 — identical copy on pf2 VRAM, pf2 scroll, pf2 region
// =====================================================================
// sc2_state is declared at the top (ModelSim forward decl)
reg [9:0]  sc2_veff;
reg [9:0]  sc2_hn;
reg [5:0]  sc2_tile;
reg [11:0] sc2_vram_idx;
reg [14:0] sc2_tile_code;
reg [3:0]  sc2_tile_pal;
reg        sc2_rom_req_tgl;
reg [31:0] sc2_rom_latch;
reg [3:0]  sc2_pix_cnt;
reg [8:0]  sc2_buf_waddr;
reg        sc2_buf_we;
// sc2_buf_wdata: 9-bit to hold 4+5 (pal[3:0] + pen[4:0]) for 5bpp.
// For standard 4bpp, pen[4] is forced to 0.
reg [8:0]  sc2_buf_wdata;
reg        sc2_half_logical;
// 5th plane (BoogieWings BG1): p4 data latch for the current half.
reg [31:0] sc2_p4_latch;

// go_latch pf2 (same as pf1)
always @(posedge clk) begin
	if (reset) begin
		pf2_go_latch <= 1'b0;
		pf2_latched_render_y <= 10'd0;
	end else begin
		if (hbl_rise) begin
			pf2_go_latch <= 1'b1;
			pf2_latched_render_y <= render_y;
		end else if (sc2_state == SC_IDLE && pf2_go_latch) begin
			pf2_go_latch <= 1'b0;
		end
	end
end

// COLSCROLL Y latched per half, pf2 (MAME 1:1).
reg [15:0] sc2_cs_value_h0;
reg [15:0] sc2_cs_value_h1;
wire [15:0] sc2_cs_value_cur = sc2_half_logical ? sc2_cs_value_h1 : sc2_cs_value_h0;
// Colscroll: cs_value is used INTACT (subtracting from it underflows to 1023 when cs=0,
// the slow part of the chimneys -> black line). The +1 lookahead is removed from sc2_veff
// on the colscroll path instead (veff >= 1 -> no underflow).
// Colscroll on:  veff_eff = render_y + scroll + cs (exactly as MAME).
// Colscroll off: veff_eff = sc2_veff = render_y+1 = sc1_veff (backgrounds aligned, no shift).
// The -1 applies ONLY to colscroll-ONLY (0x20 = MAME STANDARD tilemap path, where it is
// tuned on the chimneys — do not change that case). With row+col SIMULTANEOUS
// (0x60 = MAME custom path, Data East logo dissolve) MAME does y=src_y+coloff WITHOUT
// the -1: applying it there would move the layer by 1 line relative to the static state
// -> the logo would JUMP at the end of the effect. So with rs_en the -1 is dropped: the
// 0x60->0x00 transition is continuous and the chimneys (0x20) are unaffected.
wire [9:0]  sc2_cs_off = pf2_cs_en ? sc2_cs_value_cur[9:0] : 10'd0;
wire [9:0]  sc2_veff_eff = sc2_veff - ((pf2_cs_en && !pf2_rs_en) ? 10'd1 : 10'd0) + sc2_cs_off;

wire [5:0] sc2_col_w = (PF2_TILE_SIZE == 8) ? {1'b0, sc2_hn[8:3]} : sc2_hn[9:4];
wire [4:0] sc2_row_w = (PF2_TILE_SIZE == 8) ? sc2_veff_eff[7:3]       : sc2_veff_eff[8:4];
wire [11:0] sc2_vram_idx_calc = (PF2_TILE_SIZE == 8) ?
	{1'b0, sc2_row_w, sc2_col_w[5:0]} :
	{1'b0, sc2_col_w[5], sc2_row_w, sc2_col_w[4:0]};

reg [7:0] sc2_vram_rd_lo, sc2_vram_rd_hi;
wire [11:0] sc2_vram_raddr = ssv2 ? ss_vram_pf2.addr[11:0] : sc2_vram_idx;
always @(posedge clk) sc2_vram_rd_lo <= pf2_vram_lo[sc2_vram_raddr];
always @(posedge clk) sc2_vram_rd_hi <= pf2_vram_hi[sc2_vram_raddr];
wire [15:0] sc2_vram_rd = {sc2_vram_rd_hi, sc2_vram_rd_lo};

wire [3:0] sc2_pix_y = (PF2_TILE_SIZE == 8) ? {1'b0, sc2_veff_eff[2:0]} : sc2_veff_eff[3:0];

// Per-tile flip, pf2 (MAME deco16ic.cpp:300-311):
//   ctrl[6][8] = FLIPX, ctrl[6][9] = FLIPY (for pf2)
wire pf2_flipx_ctrl = pf12_control[6][8];
wire pf2_flipy_ctrl = pf12_control[6][9];
reg  sc2_flipx_r, sc2_flipy_r;

wire        sc2_half_eff  = ~sc2_half_logical ^ sc2_flipx_r;
wire [3:0]  sc2_pix_y_eff = sc2_flipy_r ?
                            ((PF2_TILE_SIZE == 8) ? (4'd7 - sc2_pix_y) : (4'd15 - sc2_pix_y)) :
                            sc2_pix_y;
wire [14:0] sc2_tile_code_eff = sc2_tile_code;

wire [23:0] sc2_rom_addr_w =
	(PF2_TILE_SIZE == 8) ? {4'd0, sc2_tile_code_eff, sc2_pix_y_eff[2:0], 1'b0} :
	                       {2'd0, sc2_tile_code_eff, sc2_half_eff, sc2_pix_y_eff[3:0], 1'b0};

reg [23:0] sc2_rom_addr_r;
always @(posedge clk) begin
	if (sc2_state == SC_ROM_TRIG || sc2_state == SC_ROM_REQ2)
		sc2_rom_addr_r <= sc2_rom_addr_w;
end
assign pf2_rom_addr = sc2_rom_addr_r;
assign pf2_rom_req  = sc2_rom_req_tgl;

always @(posedge clk) begin
	if (reset) begin
		sc2_state <= SC_IDLE;
		sc2_rom_req_tgl <= 1'b0;
		sc2_p4_req_tgl  <= 1'b0;
		sc2_buf_we <= 1'b0;
		sc2_buf_waddr <= 9'd0;
		sc2_flipx_r <= 1'b0;
		sc2_flipy_r <= 1'b0;
		sc2_p4_latch <= 32'd0;
	end else begin
		sc2_buf_we <= 1'b0;
		case (sc2_state)
			SC_IDLE: begin
				if (pf2_go_latch) begin
					sc2_veff <= pf2_latched_render_y + 10'd1 + pf2_scroll_y[9:0];
					sc2_hn   <= pf2_scroll_x[9:0] + (pf2_rs_en ? pf2_rs_value[9:0] : 10'd0);
					sc2_tile <= 6'd0;
					// Sub-tile X offset: waddr starts negative (= 9-bit wrap) to discard
					// the first N pixels of the first tile = MAME src_x pixel-by-pixel.
					begin : sub_offset_init2
						reg [9:0] hn_eff;
						reg [3:0] sub;
						hn_eff = pf2_scroll_x[9:0] + (pf2_rs_en ? pf2_rs_value[9:0] : 10'd0);
						sub    = (PF2_TILE_SIZE == 8) ? {1'b0, hn_eff[2:0]} : hn_eff[3:0];
						sc2_buf_waddr <= 9'd0 - {5'd0, sub};
					end
					sc2_half_logical <= 1'b0;
					sc2_cs_value_h0 <= 16'd0;
					sc2_cs_value_h1 <= 16'd0;
					sc2_state <= SC_CS_R;
				end
			end
			SC_CS_R: begin
				sc2_state <= SC_CS_WT;
			end
			SC_CS_WT: begin
				sc2_cs_value_h0 <= pf2_rs_value;
				sc2_state <= SC_VRAM_R;
			end
			SC_VRAM_R: begin
				sc2_vram_idx <= sc2_vram_idx_calc;
				sc2_state <= SC_VRAM_WT;
			end
			SC_VRAM_WT: begin
				sc2_state <= SC_VRAM_WT2;
			end
			SC_VRAM_WT2: begin
				sc2_state <= SC_ROM_REQ;
			end
			SC_ROM_REQ: begin
				sc2_tile_code <= {3'd0, sc2_vram_rd[11:0]} + pf2_bank_off;
				sc2_tile_pal  <= (sc2_vram_rd[15] && (pf2_flipx_ctrl | pf2_flipy_ctrl)) ?
				                 {1'b0, sc2_vram_rd[14:12]} : sc2_vram_rd[15:12];
				sc2_flipx_r   <= sc2_vram_rd[15] & pf2_flipx_ctrl;
				sc2_flipy_r   <= sc2_vram_rd[15] & pf2_flipy_ctrl;
				sc2_state <= SC_ROM_TRIG;
			end
			SC_ROM_TRIG: begin
				sc2_rom_req_tgl <= ~sc2_rom_req_tgl;
				sc2_state <= SC_ROM_WT;
			end
			SC_ROM_WT: begin
				if (pf2_rom_valid) begin
					sc2_rom_latch <= rom_perm_fresh_pf2;
					if (PF2_HAS_5BPP) begin
						// Trigger the p4 fetch before the draw
						sc2_state <= SC_P4_TRIG;
					end else begin
						sc2_pix_cnt <= 4'd7;
						sc2_buf_we <= 1'b1;
						sc2_state <= SC_DRAW_LO;
					end
				end
			end
			SC_P4_TRIG: begin
				// Toggle the DEDICATED CHANNEL pf2_p4_req (not shared with pf2_rom_req).
				sc2_p4_req_tgl <= ~sc2_p4_req_tgl;
				sc2_state <= SC_P4_WT;
			end
			SC_P4_WT: begin
				if (pf2_p4_valid) begin
					// p4 RAW byte (no permutation), loaded into the low byte of the latch.
					// MAME-natural bit position: sc2_pen_p4 = p4_byte[bit_pos].
					sc2_p4_latch <= {24'd0, pf2_p4_data};
					sc2_pix_cnt <= 4'd7;
					sc2_buf_we <= 1'b1;
					// After P4: go to the draw. half_logical selects: 0=draw_lo, 1=draw_hi.
					sc2_state <= sc2_half_logical ? SC_DRAW_HI : SC_DRAW_LO;
				end
			end
			SC_DRAW_LO: begin
				sc2_buf_we <= 1'b1;
				sc2_buf_waddr <= sc2_buf_waddr + 9'd1;
				if (sc2_pix_cnt == 4'd0) begin
					sc2_buf_we <= 1'b0;
					if (PF2_TILE_SIZE == 16 && sc2_half_logical == 1'b0) begin
						// h1: colscroll h1 lookup + VRAM re-fetch, then ROM_REQ2 (supports 5bpp)
						sc2_half_logical <= 1'b1;
						sc2_state <= SC_CS_R2;
					end else begin
						sc2_half_logical <= 1'b0;
						sc2_tile <= sc2_tile + 6'd1;
						sc2_hn <= sc2_hn + (PF2_TILE_SIZE == 8 ? 10'd8 : 10'd16);
						// Sub-tile offset: exit only on the tile count (waddr wraps).
						if (sc2_tile >= ((PF2_TILE_SIZE == 8) ? 6'd40 : 6'd21)) begin
							sc2_state <= SC_IDLE;
						end else begin
							sc2_state <= SC_CS_R;
						end
					end
				end else begin
					sc2_pix_cnt <= sc2_pix_cnt - 4'd1;
				end
			end
			SC_CS_R2: begin
				// Colscroll lookup half 1 (mux pf2_rs_read_idx → pf2_cs_idx_h1)
				sc2_state <= SC_CS_WT2;
			end
			SC_CS_WT2: begin
				sc2_cs_value_h1 <= pf2_rs_value;
				sc2_state <= SC_VRAM_R_H1;
			end
			SC_VRAM_R_H1: begin
				// Re-fetch VRAM with the updated sc2_veff_eff (h1)
				sc2_vram_idx <= sc2_vram_idx_calc;
				sc2_state <= SC_VRAM_WT_H1;
			end
			SC_VRAM_WT_H1: begin
				sc2_state <= SC_VRAM_WT2_H1;
			end
			SC_VRAM_WT2_H1: begin
				sc2_state <= SC_ROM_LOAD_H1;
			end
			SC_ROM_LOAD_H1: begin
				// Update tile_code/pal from VRAM h1 (possibly a new tile), then go to ROM_REQ2
				sc2_tile_code <= {3'd0, sc2_vram_rd[11:0]} + pf2_bank_off;
				sc2_tile_pal  <= (sc2_vram_rd[15] && (pf2_flipx_ctrl | pf2_flipy_ctrl)) ?
				                 {1'b0, sc2_vram_rd[14:12]} : sc2_vram_rd[15:12];
				sc2_flipx_r   <= sc2_vram_rd[15] & pf2_flipx_ctrl;
				sc2_flipy_r   <= sc2_vram_rd[15] & pf2_flipy_ctrl;
				sc2_state <= SC_ROM_REQ2;
			end
			SC_ROM_REQ2: begin
				sc2_rom_req_tgl <= ~sc2_rom_req_tgl;
				sc2_state <= SC_ROM_WT2;
			end
			SC_ROM_WT2: begin
				if (pf2_rom_valid) begin
					sc2_rom_latch <= rom_perm_fresh_pf2;
					if (PF2_HAS_5BPP) begin
						sc2_state <= SC_P4_TRIG;  // then P4_WT, then DRAW_HI (see half=1)
					end else begin
						sc2_pix_cnt <= 4'd7;
						sc2_buf_we <= 1'b1;
						sc2_state <= SC_DRAW_HI;
					end
				end
			end
			SC_DRAW_HI: begin
				sc2_buf_we <= 1'b1;
				sc2_buf_waddr <= sc2_buf_waddr + 9'd1;
				if (sc2_pix_cnt == 4'd0) begin
					sc2_buf_we <= 1'b0;
					sc2_half_logical <= 1'b0;
					sc2_tile <= sc2_tile + 6'd1;
					sc2_hn <= sc2_hn + 10'd16;
					// Sub-tile offset: exit only on the tile count.
					if (sc2_tile >= ((PF2_TILE_SIZE == 8) ? 6'd40 : 6'd21)) begin
						sc2_state <= SC_IDLE;
					end else begin
						sc2_state <= SC_CS_R;
					end
				end else begin
					sc2_pix_cnt <= sc2_pix_cnt - 4'd1;
				end
			end
			default: sc2_state <= SC_IDLE;
		endcase
	end
end

wire [2:0] bit_pos_pf2 = sc2_flipx_r ? sc2_pix_cnt[2:0] : (3'd7 - sc2_pix_cnt[2:0]);
// 5th plane (BoogieWings BG1) — runtime permutations (values set by the top).
// sc2_p4_latch = {24'd0, raw p4 byte from the bridge}.
//
// Permutation pipeline:
//   1) byte_pos (2-bit) : selects one of the 4 bytes of the latch (targeted extraction,
//                         no global swap that would bring garbage elsewhere)
//   2) brev8            : optional bit-reverse of the selected byte
//   3) bit_shift        : optional 1 bit-position shift (offset test)
function [7:0] brev8_p4(input [7:0] b);
	brev8_p4 = {b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]};
endfunction
reg [7:0] p4_byte_sel;
always @(*) begin
	case (osd_p4_byte_pos)
		2'd0: p4_byte_sel = sc2_p4_latch[7:0];
		2'd1: p4_byte_sel = sc2_p4_latch[15:8];
		2'd2: p4_byte_sel = sc2_p4_latch[23:16];
		2'd3: p4_byte_sel = sc2_p4_latch[31:24];
	endcase
end
wire [7:0]  p4_byte = osd_p4_brev8 ? brev8_p4(p4_byte_sel) : p4_byte_sel;
wire [2:0]  p4_bit_pos = bit_pos_pf2 ^ (osd_p4_bit_shift ? 3'd1 : 3'd0);
wire        sc2_pen_p4 = (PF2_HAS_5BPP) ? p4_byte[p4_bit_pos] : 1'b0;
wire [3:0] sc2_pen_4b = {
	sc2_rom_latch[5'd24 + {2'd0, bit_pos_pf2}],
	sc2_rom_latch[5'd16 + {2'd0, bit_pos_pf2}],
	sc2_rom_latch[5'd8  + {2'd0, bit_pos_pf2}],
	sc2_rom_latch[{2'd0, bit_pos_pf2}]
};
wire [4:0] sc2_pen5 = {sc2_pen_p4, sc2_pen_4b};
// sc2_buf_wdata: 9-bit = {pal[3:0], pen[4:0]}. 5bpp uses pen5, 4bpp has pen[4]=0.
always @(*) sc2_buf_wdata = (PF2_HAS_5BPP) ? {sc2_tile_pal, sc2_pen5}
                                            : {sc2_tile_pal, 1'b0, sc2_pen_4b};

(* ramstyle = "M10K", no_rw_check *) reg [8:0] linebuf2_a [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [8:0] linebuf2_b [0:511];
integer ii_lb2;
initial for (ii_lb2=0; ii_lb2<512; ii_lb2=ii_lb2+1) begin
	linebuf2_a[ii_lb2] = 9'd0; linebuf2_b[ii_lb2] = 9'd0;
end

// Write: 1 always per array → M10K-safe inference
// waddr<320 gating (the sub-tile X offset wrap sends the unsigned waddr to 496..511).
wire sc2_buf_we_g = sc2_buf_we && (sc2_buf_waddr < 9'd320);
always @(posedge clk) if (sc2_buf_we_g &&  lb2_sel == 1'b0) linebuf2_a[sc2_buf_waddr] <= sc2_buf_wdata;
always @(posedge clk) if (sc2_buf_we_g &&  lb2_sel == 1'b1) linebuf2_b[sc2_buf_waddr] <= sc2_buf_wdata;

// Read: 1 always per array, mux AFTER the read → M10K safe
reg [8:0] lb2_a_rd, lb2_b_rd;
reg       lb2_sel_d;
always @(posedge clk) lb2_a_rd <= linebuf2_a[render_x[8:0]];
always @(posedge clk) lb2_b_rd <= linebuf2_b[render_x[8:0]];
always @(posedge clk) lb2_sel_d <= lb2_sel;
reg [8:0] lb2_rd;
always @(posedge clk) lb2_rd <= (lb2_sel_d == 1'b0) ? lb2_b_rd : lb2_a_rd;

// =====================================================================
// Output pixel (pen + col + opaque)
// =====================================================================
wire [3:0] pf1_pen_raw = lb1_rd[3:0];
wire [3:0] pf1_pal_raw = lb1_rd[7:4];
// pf2: lb2_rd = {pal[3:0], pen[4:0]} (9-bit). 4bpp has pen[4]=0 (bit 4 unused).
wire [4:0] pf2_pen_raw = lb2_rd[4:0];
wire [3:0] pf2_pal_raw = lb2_rd[8:5];

assign pf1_pix    = pf1_pen_raw;
assign pf1_col    = {1'b0, pf1_pal_raw & PF1_COL_MASK} + PF1_COL_BANK;
assign pf1_opaque = pf1_enable & (|pf1_pen_raw);

assign pf2_pix    = pf2_pen_raw;
assign pf2_col    = {1'b0, pf2_pal_raw & PF2_COL_MASK} + PF2_COL_BANK;
assign pf2_opaque = pf2_enable & (|pf2_pen_raw);

endmodule
