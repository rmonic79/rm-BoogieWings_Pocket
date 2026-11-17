//
// boogwings_top.sv
// Boogie Wings top level (Data East, 1992)
//
// Hardware (MAME boogwing.cpp):
//   Main CPU:    M68000 @ 14 MHz (28/2)         — DE102 encrypted opcodes
//   Sound CPU:   H6280  @ 8.055 MHz (32.22/4)
//   Tilemap:     DECO16IC × 2  (4 BG layers in total)
//   Sprite:      DECO_SPRITE × 2 (alpha-blend)
//   Palette:     DECO_ACE (palette + alpha)
//   I/O+protect: DECO104PROT
//   Audio:       YM2151 @ 3.58 MHz + OKIM6295 × 2 (1 MHz and 2 MHz)
//
// Memory map main (boogwing.cpp:504):
//   0x000000-0x0FFFFF  ROM (1MB, encrypted)
//   0x200000-0x20FFFF  work RAM (64KB)
//   0x220000           priority_w
//   0x240000/0x244000  spriteram DMA trigger
//   0x242000/0x246000  spriteram1/2 (2KB each)
//   0x24E000-0x24EFFF  DECO104 protection RAM + I/O
//   0x260000-0x267FFF  deco16ic[0] control + pf1 + pf2
//   0x268000-0x26AFFF  rowscroll pf1/pf2
//   0x270000-0x277FFF  deco16ic[1] control + pf1 + pf2
//   0x278000-0x27AFFF  rowscroll pf3/pf4
//   0x282008           palette DMA trigger
//   0x284000-0x285FFF  palette RAM (8KB)
//   0x3C0000-0x3C004F  deco_ace control (ACE alpha)
//
// Memory map audio H6280 (boogwing.cpp:547):
//   0x000000-0x00FFFF  ROM (64KB)
//   0x110000           YM2151 r/w
//   0x120000           OKI1 r/w
//   0x130000           OKI2 r/w
//   0x140000           sound latch read
//   0x1F0000-0x1F1FFF  work RAM (8KB)
//
// IRQ:
//   Main IRQ6 = VBLANK (irq6_line_hold)
//   H6280 IRQ0 = sound latch (DECO104 soundlatch_irq_cb)
//   H6280 IRQ2 = YM2151 IRQ
//

module boogwings_top
(
	input  wire        clk,
	input  wire        reset,
	input  wire        pause,

	// Savestate triggers (from savestate_ui)
	input  wire        ss_save,
	input  wire        ss_load,
	input  wire [4:0]  ss_slot,   // 32 slots: [4:3]=region (files .ss1-.ss4), [2:0]=sub-slot

	// Inputs, MAME mapping for Boogie Wings:
	//   inputs_port = INPUTS (16-bit, P1+P2 joy+button+start, active LOW)
	//   system_port = SYSTEM (16-bit, coin+service+vblank, active LOW except vblank)
	//   dsw_port    = DSW    (16-bit DIP switches)
	input  wire [15:0] inputs_port,
	input  wire [15:0] system_port,
	input  wire [15:0] dsw_port,

	// SDRAM ROM interface (via sdram_bridge): main + tile ports
	// (Boogie Wings has no sub CPU)
	output wire [23:0] main_rom_addr,
	output wire        main_rom_is_opcode,   // dual-view fetch: selects the opcode or data view
	output wire        main_rom_req,
	input  wire [15:0] main_rom_rdata,
	input  wire        main_rom_ready,

	// Tile ROM FG0 (chip1.pf1) — direct jtframe ba0, no arbiter
	output wire [23:0] tilerom_fg0_addr,
	output wire [2:0]  tilerom_fg0_region_id,
	output wire        tilerom_fg0_req,
	input  wire [31:0] tilerom_fg0_data,
	input  wire        tilerom_fg0_valid,

	// Tile ROM FG1 (chip1.pf2) — direct jtframe ba1, no arbiter
	output wire [23:0] tilerom_fg1_addr,
	output wire [2:0]  tilerom_fg1_region_id,
	output wire        tilerom_fg1_req,
	input  wire [31:0] tilerom_fg1_data,
	input  wire        tilerom_fg1_valid,

	// Tile ROM BG1 (chip0.pf2 5bpp) — dedicated SDRAM ba3 (4 base planes + dedicated P4)
	output wire [23:0] tilerom_bg1_addr,
	output wire        tilerom_bg1_req,
	input  wire [31:0] tilerom_bg1_data,
	input  wire        tilerom_bg1_valid,
	output wire        tilerom_bg1_p4_req,
	input  wire  [7:0] tilerom_bg1_p4_data,
	input  wire        tilerom_bg1_p4_valid,

	// ioctl (ROM download)
	input  wire        ioctl_download,
	input  wire        ioctl_wr,
	input  wire [26:0] ioctl_addr,
	input  wire [15:0] ioctl_dout,
	input  wire [15:0] ioctl_index,
	output wire        ioctl_wait,

	// Video pixel interface
	input  wire [9:0]  render_x,
	input  wire [9:0]  render_y,
	input  wire        hblank_in,
	input  wire        vblank_in,
	input  wire        ce_pix,
	input  wire        ce_audio,    // ~8 MHz, for the H6280 audio CPU
	input  wire        ce_ym,       // ~3.58 MHz, for the YM2151
	input  wire        ce_ym_p1,    // ~1.79 MHz, half rate for jt51
	input  wire        ce_oki0,     // ~1.01 MHz, for OKI #0
	input  wire        ce_oki1,     // ~2.00 MHz, for OKI #1
	// Savestate of the ce counter phases (from/to Template.sv): in = save, out + load_wr = restore.
	input  wire [3:0]  ce_audio_cnt_in,
	input  wire [4:0]  ce_ym_cnt_in,
	input  wire        ce_ym_toggle_in,
	input  wire [6:0]  ce_oki0_cnt_in,
	input  wire [5:0]  ce_oki1_cnt_in,
	output wire [3:0]  ce_audio_cnt_load,
	output wire [4:0]  ce_ym_cnt_load,
	output wire        ce_ym_toggle_load,
	output wire [6:0]  ce_oki0_cnt_load,
	output wire [5:0]  ce_oki1_cnt_load,
	output wire        ce_cnt_load_wr,
	// OSD audio sel (4 bit each) — Default/MAME hardcoded inside boogwings_audio
	input  wire [3:0]  osd_sel_fm,
	input  wire [3:0]  osd_sel_oki0,
	input  wire [3:0]  osd_sel_oki1,
	input  wire [1:0]  osd_presence,   // high shelf on the mix: 0 Off, 1 +3, 2 +6, 3 +9 dB
	output wire [23:0] rgb_out,

	// Audio
	output wire signed [15:0] audio_l,
	output wire signed [15:0] audio_r,
	output wire        paused_safe,    // frame-aligned gating for the ce counters in Template.sv

	// DDRAM HPS pins (OKI samples, sprite ROM)
	input  wire        DDRAM_CLK,
	input  wire        DDRAM_BUSY,
	output wire  [7:0] DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output wire        DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire  [7:0] DDRAM_BE,
	output wire        DDRAM_WE,
	// POCKET: text ROM (tile1) in SDRAM, bank ba3, through sdram_bridge
	output wire [23:0] txt_rom_addr,
	output wire        txt_rom_req,
	input  wire [31:0] txt_rom_data,
	input  wire        txt_rom_valid,

	// === Layer enable OSD (runtime mask) ===
	input  wire        layer_bg0_en,   // chip0 pf1 (text)
	input  wire        layer_bg1_en,   // chip0 pf2 (BG1)
	input  wire        layer_spr_en,   // sprite
	input  wire        layer_fg0_en,   // chip1 pf1+pf2 (BG2)

	// === Layer FG1 (chip1.pf2, separate from FG0) ===
	input  wire        layer_fg1_en,

	// Tile permutation toggles (16 = 4 perm × 4 layer bg0/bg1/fg0/fg1) + sprite
	input  wire        osd_bg0_swap_hl,
	input  wire        osd_bg0_brev8,
	input  wire        osd_bg0_nibsw,
	input  wire        osd_bg0_bs_ab,
	input  wire        osd_bg1_swap_hl,
	input  wire        osd_bg1_brev8,
	input  wire        osd_bg1_nibsw,
	input  wire        osd_bg1_bs_ab,
	input  wire        osd_fg0_swap_hl,
	input  wire        osd_fg0_brev8,
	input  wire        osd_fg0_nibsw,
	input  wire        osd_fg0_bs_ab,
	input  wire        osd_fg1_swap_hl,
	input  wire        osd_fg1_brev8,
	input  wire        osd_fg1_nibsw,
	input  wire        osd_fg1_bs_ab,
	input  wire        osd_spr_swap_hl,
	input  wire        osd_spr_brev8,
	input  wire        osd_spr_nibsw,
	input  wire        osd_spr_bs_ab,
	input  wire        osd_spr_msb_first,
	input  wire        osd_spr_half_inv,
	input  wire        osd_spr_half_eff_inv,
	input  wire        osd_spr_row_inv,
	input  wire        osd_spr_plane_inv,
	input  wire [1:0]  osd_spr_p0_src,
	input  wire [1:0]  osd_spr_p1_src,
	input  wire [1:0]  osd_spr_p2_src,
	input  wire [1:0]  osd_spr_p3_src,
	input  wire [1:0]  osd_spr_chip_filter,  // 00=both, 01=chip0, 10=chip1, 11=none
	input  wire        osd_spr_w_swap_pos,          // w-mode: swap position of 1st/2nd block
	input  wire        osd_spr_w_offset_first,      // w-mode: apply offset to the 1st block (absolute X debug)
	input  wire        osd_spr_w_code_swap,         // w-mode: swap code of first/second block
	input  wire signed [3:0] osd_spr_w_offset,      // w-mode: offset X signed (step 16)

	// BG1 p4 (plane 4 mbd-02) permutation toggles
	input  wire [1:0]  osd_bg1_p4_byte_pos,
	input  wire        osd_bg1_p4_brev8,
	input  wire        osd_bg1_p4_bit_shift
);

// GFX debug permutations: tied to their default values.
wire [4:0] osd_tile_decode_mode = 5'd0;
wire       osd_pixel_bit_msb    = 1'b0;
wire       osd_plane_rev32      = 1'b0;
wire       osd_nibble_swap      = 1'b0;
wire       osd_byte_swap_ab     = 1'b0;
wire       osd_xhalf_inv        = 1'b0;
wire       osd_tile_hi_rev      = 1'b0;
wire [1:0] osd_vram_swizzle     = 2'd0;

// =====================================================================
// MAIN CPU M68000 @ 14 MHz (target, MAME = 28MHz/2)
// jtframe_68kdtack_cen generates cpu_cen/cpu_cenb with cycle recovery
// when the bus is busy (e.g. waiting for SDRAM). Pause = cen gating, never reset.
// =====================================================================

// Clock divider: clk_sys 96 MHz × 7/48 = exactly 14.000 MHz
// MAME M68K main = 28 MHz / 2 = 14.000 MHz (boogwing.cpp:715,719)
localparam [6:0] CPU_NUM = 7'd7;
localparam [7:0] CPU_DEN = 8'd48;

wire        cpu_cen, cpu_cenb;
wire        cpu_dtackn;
wire [23:0] cpu_addr;
wire        cpu_rd, cpu_wr;
wire [15:0] cpu_wdata;
wire [1:0]  cpu_dsn;
wire [15:0] cpu_rdata;
wire        cpu_iack;
wire [2:0]  cpu_fc;
wire        cpu_fx_asn;
wire [1:0]  cpu_fx_dsn;

// Address decoder forward declarations (for ModelSim 10.5b, no forward references)
wire is_rom, is_ram, is_prio, is_spr1, is_spr2, is_sprdma1, is_sprdma2;
wire is_prot, is_pf0, is_pf1, is_paldma, is_pal, is_ace;
// DECO16IC chip 0 control mirror (range 0x24C000-0x24CFFF, found in the
// main disassembly at 0xA94: it writes the ctrl regs via $24C100..$24C600, stride 0x100).
// Chip 0 decodes partially: cpu_addr[10:8] = ctrl index.
wire is_pf0_mirror;
// MAME noprw ranges (boogwing.cpp:510, 534, 535) — they must produce DTACK, but
// writes/reads have no effect (read=FFFF, write ignored).
wire is_noprw;

// bus_cs = the CPU is accessing a mapped space.
// bus_busy = the target is not ready yet. For ROM: ~main_rom_ready (cache).
//            For RAM/palette/sprite/deco16ic/ace (= BRAM read): 1 ck wait to
//            let the BRAM output settle (1-ck latency). This is done by
//            asserting bus_busy=1 in the cycle IN WHICH the request is new, then 0
//            in the next cycle (= data ready).
//
// NOTE: the 0x24XXXX mirror (generic DECO104 range) is caught by is_prot for
// 0x24E000-0x24EFFF; the other sub-ranges of the 0x24 mirror are redundant.
wire is_io_mirror = (cpu_addr[23:16] == 8'h24) && !is_spr1 && !is_spr2
                    && !is_sprdma1 && !is_sprdma2 && !is_prot && !is_pf0_mirror;
wire bus_cs   = is_rom | is_ram | is_pf0 | is_pf0_mirror | is_pf1 | is_pal | is_ace |
                 is_spr1 | is_spr2 | is_sprdma1 | is_sprdma2 | is_prio | is_prot |
                 is_paldma | is_io_mirror | is_noprw;

// jtframe_68kdtack_cen already has its own internal wait1 that gives 1 extra cycle
// after AS falls, so no bram_wait is needed. ram_dout_r (BRAM 1-ck read
// latency) is ready at the cpu_cen that jtframe uses to sample bus_busy.
// DECO104 read latency: 1-ck registered pipeline. 1 ck of bus_busy is
// added to give the read time to propagate to prot_cpu_rd.
reg prot_busy_r;
always @(posedge clk) begin
	if (reset) prot_busy_r <= 1'b0;
	else       prot_busy_r <= is_prot & cpu_rd & ~prot_busy_r;
end

// Tile VRAM pf0/pf1: 1 ck wait to make sure the CPU write reaches the
// BRAM before the CPU moves on to the next bus cycle. Without the wait, under stress
// (= back-to-back VRAM writes at CPU rate) some writes can be silently lost
// to a timing race (pf0/pf1 VRAM left unpopulated).
reg pf_busy_r;
wire pf_wr_active = (is_pf0 | is_pf0_mirror | is_pf1) & cpu_wr;
always @(posedge clk) begin
	if (reset) pf_busy_r <= 1'b0;
	else       pf_busy_r <= pf_wr_active & ~pf_busy_r;
end

wire bus_busy = (is_rom & cpu_rd & ~main_rom_ready) | (is_prot & cpu_rd & ~prot_busy_r) | (pf_wr_active & ~pf_busy_r);

jtframe_68kdtack_cen #(.W(8), .RECOVERY(1)) u_dtack (
	.rst      (reset),
	.clk      (clk),
	.cpu_cen  (cpu_cen),
	.cpu_cenb (cpu_cenb),
	.bus_cs   (bus_cs),
	.bus_busy (bus_busy),
	.bus_legit(1'b0),
	.bus_ack  (1'b0),
	.ASn      (cpu_fx_asn),
	.DSn      (cpu_fx_dsn),
	.num      (CPU_NUM),
	.den      (CPU_DEN),
	.wait2    (1'b0),
	.wait3    (1'b0),
	.DTACKn   (cpu_dtackn),
	.fave     (),
	.fworst   ()
);

// === VBlank-synced pause (frame-aligned, same scheme as the Taito F2 obj_paused) ===
// Raw pause is asynchronous (toggles on the key press mid-frame) → registered paused_safe that
// changes ONLY on the vblank rising edge (frame boundary). Avoids races mid bus cycle /
// scanline / DDR3. Used on the CPU (cen) + audio (YM/OKI cen + HuC via RDY). The sprites
// freeze by themselves: the renderer draws the buffer, and the DMA copies the frozen live RAM
// (the CPU that writes it is paused) -> static sprite image.
reg vblank_pp_d;
reg paused_safe_r;
always @(posedge clk) begin
	if (reset) begin
		vblank_pp_d   <= 1'b0;
		paused_safe_r <= 1'b0;
	end else begin
		vblank_pp_d <= vblank_in;
		// paused_safe_r = REAL frame-aligned pause (= F2 obj_paused). ONE single, clear assignment:
		//   - RISE: only on the vblank rising edge, if (pause | ss_pause) -> the SAVE captures on a frame
		//     boundary, never mid-frame (clean video/audio).
		//   - HOLD during SS: if ss_pause is high and paused_safe_r is already high, it STAYS high
		//     (does not wait for the next vblank). Without this, if a vblank boundary falls while
		//     memory_stream writes the audio chips (idx 20-25, the last ones), ce_ym/ce_oki would restart
		//     in the MIDDLE of the scatter -> the chip receives registers while its counter runs -> sometimes
		//     mute, sometimes glitchy (random phase = non-deterministic, right at restore).
		//   - FALL: during SS it falls AT ONCE when ss_pause drops (restore done) -> HuC+68k+chips
		//     restart in the SAME cycle. User pause: falls at vblank.
		// Transparent with SS idle (ss_pause=0): rises/falls at vblank only.
		if (ss_pause & paused_safe_r)
			paused_safe_r <= 1'b1;                          // hold high for the whole SS
		else if (vblank_in & ~vblank_pp_d)
			paused_safe_r <= pause | ss_pause;              // frame-aligned RISE on pause|ss_pause;
			                                               // FALL: with SS off ss_pause=0 -> follows pause

	end
end
// Effective pause = ONLY the safe pause REGISTERED at vblank (paused_safe_r). Both user pause
// and savestate go through the frame-aligned sampling (paused_safe_r samples
// pause|ss_pause on the vblank rising edge). NO OR with the combinational ss_pause: that would stop
// the savestate MID-FRAME (bypassing vblank) -> VRAM/palette/sprites/audio captured
// mid-transition -> corrupted backgrounds/palette, audio glitches. EVERYTHING stops ONLY at vblank,
// like the user pause (which freezes cleanly).
// paused_safe is an output port (it gates the ce counters in Template.sv; the gating is inside the
// counter, like F2 .cen_in, not an external AND on the pulse).
assign paused_safe = paused_safe_r;

// Pause: cen gating (NOT reset). During SS the CPU MUST run to execute the mini-handler
// (ss_cpu_exec), so it is not stopped in that case even when paused.
wire cpu_run    = ~paused_safe | ss_cpu_exec;
wire cpu_cen_g  = cpu_cen  & cpu_run;
wire cpu_cenb_g = cpu_cenb & cpu_run;

// IRQ: VBLANK rising edge → IRQ6 held until the CPU acknowledges it (iack).
// MAME: irq6_line_hold = keep IRQ6 high, MAME clears it when the CPU does IACK.
// During SAVE the SS module forces IRQ7 (ss_irq) to make the CPU take the exception.
reg vblank_d;
reg irq6_pending;
always @(posedge clk) begin
	vblank_d <= vblank_in;
	if (reset) irq6_pending <= 1'b0;
	else if (vblank_in & ~vblank_d) irq6_pending <= 1'b1;  // rising edge VBLANK
	else if (cpu_iack)              irq6_pending <= 1'b0;
	else if (misc_ss_wr)            irq6_pending <= misc_irq6_load;   // restore (transparent)
end
wire [2:0] cpu_irq_level = ss_irq        ? 3'd7 :
                           irq6_pending  ? 3'd6 : 3'd0;

// cpu_din: during SS the module injects the handler/vector instead of the normal bus.
wire [15:0] cpu_din_eff = ss_din_en ? ss_din_data : cpu_rdata;

cpu68000_wrapper u_maincpu (
	.clk        (clk),
	.reset      (reset | ss_reset),
	.ce_cpu     (cpu_cen_g),
	.ce_cpub    (cpu_cenb_g),
	.bus_rdata  (cpu_din_eff),
	.bus_dtackn (cpu_dtackn),
	.irq_level  (cpu_irq_level),
	.active     (),
	.cycles     (),
	.bus_addr   (cpu_addr),
	.bus_rd     (cpu_rd),
	.bus_wr     (cpu_wr),
	.bus_wdata  (cpu_wdata),
	.bus_dsn_out(cpu_dsn),
	.fx_asn     (cpu_fx_asn),
	.fx_dsn     (cpu_fx_dsn),
	.last_read  (),
	.dbg_pc     (),
	.iack       (cpu_iack),
	.fc         (cpu_fc)
);

// Opcode fetch: 68K FC=2 (user prog) or FC=6 (supervisor prog)
wire cpu_is_opcode = (cpu_fc == 3'd2) || (cpu_fc == 3'd6);

// =====================================================================
// DE102 decryption (DECO102 chip)
//   address scramble: i_logical → i_physical (ROM offset)
//   data decrypt:     din × addr × select_xor → plain
// Parameters boogwing.cpp:1027:
//   address_xor=0x42BA, data_select_xor=0x00, opcode_select_xor=0x18
// The FPGA decrypts the main ROM while it is downloaded (de102_ioctl_decrypt.sv):
// SDRAM holds a decrypted opcode view and a decrypted data view, selected by
// main_rom_is_opcode.
// =====================================================================
wire [19:0] scrambled_addr;
wire [15:0] rom_plain;

// SDRAM already holds the decrypted views: no runtime scramble or decrypt here.
assign scrambled_addr = cpu_addr[19:0];
assign rom_plain      = main_rom_rdata;

// =====================================================================
// MAIN address decoder (boogwing.cpp:504)
// =====================================================================
// 0x000000-0x0FFFFF  ROM (SDRAM)
// 0x200000-0x20FFFF  work RAM 64KB
// 0x220000           priority_w
// 0x240000-0x247FFF  sprite RAM + DMA
// 0x24E000-0x24EFFF  DECO104 protection
// 0x260000-0x26AFFF  DECO16IC[0] tilemap + rowscroll
// 0x270000-0x27AFFF  DECO16IC[1] tilemap + rowscroll
// 0x282008           palette DMA
// 0x284000-0x285FFF  palette RAM
// 0x3C0000-0x3C004F  DECO_ACE control
assign is_rom    = (cpu_addr[23:20] == 4'h0);                    // 0x000000-0x0FFFFF
assign is_ram    = (cpu_addr[23:16] == 8'h20);                   // 0x200000-0x20FFFF
assign is_prio   = (cpu_addr[23:16] == 8'h22) && (cpu_addr[15:1] == 15'd0);
// MAME: 0x242000-0x2427FF (2 KB = 0x800 bytes).
assign is_spr1   = (cpu_addr[23:11] == 13'h484);                 // 0x242000-0x2427FF
assign is_spr2   = (cpu_addr[23:11] == 13'h48C);                 // 0x246000-0x2467FF
assign is_sprdma1= (cpu_addr[23:1] == {16'h2400, 7'd0});         // 0x240000
assign is_sprdma2= (cpu_addr[23:1] == {16'h2440, 7'd0});         // 0x244000
assign is_prot   = (cpu_addr[23:12] == 12'h24E);                 // 0x24E000-0x24EFFF
assign is_pf0    = (cpu_addr[23:14] == 10'h098) || (cpu_addr[23:14] == 10'h099) ||  // 0x260000-0x267FFF
                    (cpu_addr[23:14] == 10'h09A) || (cpu_addr[23:14] == 10'h09B);
assign is_pf1    = (cpu_addr[23:14] == 10'h09C) || (cpu_addr[23:14] == 10'h09D) ||  // 0x270000-0x27AFFF
                    (cpu_addr[23:14] == 10'h09E) || (cpu_addr[23:14] == 10'h09F);
assign is_paldma = (cpu_addr[23:4] == 20'h28200) && (cpu_addr[3:1] == 3'd4);  // 0x282008
assign is_pal    = (cpu_addr[23:13] == 11'h142);                 // 0x284000-0x285FFF
assign is_ace    = (cpu_addr[23:7] == 17'h7800);                 // 0x3C0000-0x3C004F (approx)

// DECO16IC chip 0 mirror: the main ROM (disasm 0xA94..0xABC) writes control
// regs at $24C100, $24C200, ..., $24C600. Chip 0 decodes partially and
// answers here too. cpu_addr[10:8] = ctrl word index (1..6 = scroll+mode).
assign is_pf0_mirror = (cpu_addr[23:12] == 12'h24C);

// Noprw ranges (MAME boogwing.cpp:510, 534, 535):
//   0x220002-0x22FFFF : after priority_w
//   0x280000-0x28000F : palette setup (except 0x282008 = paldma)
//   0x282000-0x282001 : palette setup
wire is_noprw_220 = (cpu_addr[23:16] == 8'h22) && !is_prio;
wire is_noprw_280 = (cpu_addr[23:4] == 20'h28000);
wire is_noprw_282 = (cpu_addr[23:1] == {16'h2820, 7'd0}) && !is_paldma;
assign is_noprw   = is_noprw_220 | is_noprw_280 | is_noprw_282;

// ROM bridge address (scrambled_addr, equal to the CPU address here), request and
// view select are registered to avoid a long combinational path out of the module.
reg [23:0] main_rom_addr_r;
reg        main_rom_req_r;
reg        main_rom_is_opcode_r;
always @(posedge clk) begin
	main_rom_addr_r      <= {4'd0, scrambled_addr};
	main_rom_req_r       <= is_rom & cpu_rd;
	main_rom_is_opcode_r <= cpu_is_opcode;
end
assign main_rom_addr       = main_rom_addr_r;
assign main_rom_req        = main_rom_req_r;
assign main_rom_is_opcode  = main_rom_is_opcode_r;

// === SAVESTATE — bus declarations (must precede the first adaptor) ===
// SS_IDX_* = unique index of each state block. SS_NSLAVES = number of slaves.
localparam SS_IDX_WORKRAM    = 0;
localparam SS_IDX_SPR1       = 1;
localparam SS_IDX_SPR2       = 2;
localparam SS_IDX_PAL_CPU    = 3;
localparam SS_IDX_C1_PF1_MIR = 4;
localparam SS_IDX_C1_PF2_MIR = 5;
// chip0 (u_deco16_0): VRAM pf1/pf2, rowscroll pf1/pf2, control
localparam SS_IDX_C0_VRAM_PF1 = 6;
localparam SS_IDX_C0_VRAM_PF2 = 7;
localparam SS_IDX_C0_RS_PF1   = 8;
localparam SS_IDX_C0_RS_PF2   = 9;
localparam SS_IDX_C0_CTRL     = 10;
// chip1 (u_deco16_1): VRAM pf1/pf2, rowscroll pf1/pf2, control
localparam SS_IDX_C1_VRAM_PF1 = 11;
localparam SS_IDX_C1_VRAM_PF2 = 12;
localparam SS_IDX_C1_RS_PF1   = 13;
localparam SS_IDX_C1_RS_PF2   = 14;
localparam SS_IDX_C1_CTRL     = 15;
localparam SS_IDX_HUC_RAM     = 16;
localparam SS_IDX_GLOBAL      = 17;   // 68000 SSP (ss_m68k module)
// chip0 VRAM shadow mirror (CPU readback pf1/pf2) — see the chip0 mirror block below
localparam SS_IDX_C0_PF1_MIR  = 18;
localparam SS_IDX_C0_PF2_MIR  = 19;
localparam SS_IDX_HUC_CPU     = 20;   // HUC6280 internal state (auto_ss, 298 bit)
localparam SS_IDX_OKI0        = 21;   // OKI #0 internal state (jt6295, auto_ss 359 bit)
localparam SS_IDX_OKI1        = 22;   // OKI #1 internal state (jt6295, auto_ss 359 bit)
localparam SS_IDX_YM          = 23;   // YM2151 internal state (jt51, auto_ss 2820 bit)
localparam SS_IDX_ACE         = 24;   // DECO ACE register file (blend/alpha/fade, 64x16)
localparam SS_IDX_AUDIO_BUS   = 25;   // persistent state of the audio wrapper (sndlatch FIFO + YM/OKI ctrl + ce counter phases, 186 bit)
localparam SS_IDX_MISC        = 26;   // sprite DMA + palette DMA + priority_reg + irq6_pending (74 bit)
localparam SS_IDX_DECO104     = 27;   // DECO104 protection regs (xor/nand/bank/latch/soundlatch, 70 bit)
localparam SS_IDX_DC_RB0      = 28;   // DECO104 rambank0 (protection RAM 128x16)
localparam SS_IDX_DC_RB1      = 29;   // DECO104 rambank1 (protection RAM 128x16)
localparam SS_NSLAVES         = 30;
// memory_stream COUNT (>= SS_NSLAVES, power of 2). With SS_NSLAVES>16, COUNT>=32 is needed.
localparam SS_MS_COUNT        = 32;
ssbus_if ssbus();
ssbus_if ssb[SS_NSLAVES]();

// Work RAM 64KB (32K × 16-bit, byte enable). CPU access only.
// M10K forced to avoid LUT-RAM for 64KB (it would be ~500k LUTs).
(* ramstyle = "M10K", no_rw_check *) reg [7:0] ram_lo [0:32767];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] ram_hi [0:32767];
// Write and read in one always block infer 32K FFs. Separate blocks = safe M10K.
reg [7:0] ram_dout_hi_r, ram_dout_lo_r;
wire [15:0] ram_dout_r = {ram_dout_hi_r, ram_dout_lo_r};
wire [14:0] ram_idx_cpu = cpu_addr[15:1];
wire we_lo_cpu = is_ram & cpu_wr & ~cpu_dsn[0];
wire we_hi_cpu = is_ram & cpu_wr & ~cpu_dsn[1];

// Savestate adaptor in series on the CPU port (NO extra BRAM): with SS idle it passes the
// game signals; during SS it redirects the port to the savestate bus (SS_IDX_WORKRAM).
wire [14:0] ram_idx;
wire        we_lo, we_hi;
wire [15:0] ram_wdata_eff;
ss_ram16_adaptor #(.WIDTHAD(15), .SS_IDX(SS_IDX_WORKRAM)) workram_ss (
	.clk      (clk),
	.we_lo_in (we_lo_cpu),
	.we_hi_in (we_hi_cpu),
	.addr_in  (ram_idx_cpu),
	.wdata_in (cpu_wdata),
	.we_lo_out(we_lo),
	.we_hi_out(we_hi),
	.addr_out (ram_idx),
	.wdata_out(ram_wdata_eff),
	.q_in     (ram_dout_r),
	.ssbus    (ssb[SS_IDX_WORKRAM])
);

always @(posedge clk) if (we_hi) ram_hi[ram_idx] <= ram_wdata_eff[15:8];
always @(posedge clk) if (we_lo) ram_lo[ram_idx] <= ram_wdata_eff[7:0];
always @(posedge clk) ram_dout_hi_r <= ram_hi[ram_idx];
always @(posedge clk) ram_dout_lo_r <= ram_lo[ram_idx];
wire [15:0] ram_dout = ram_dout_r;

// ROM bus: uses rom_plain (decrypted)
// Forward declarations for ModelSim 10.5b
wire [15:0] spr1_cpu_rd, spr2_cpu_rd, ace_cpu_rd, d16_0_cpu_rdata, d16_1_cpu_rdata;
wire [15:0] prot_cpu_rd;

// =====================================================================
// Chip1 VRAM shadow mirror.
// MAME boogwing.cpp:529-530: chip1 pf1/pf2 mapped with `.ram().w(deco16ic)`.
// = a write goes both to the CPU shadow RAM and to the deco16ic.
// CPU readback MUST read the shadow (not the deco16ic shared with the scan).
// Without the mirror: CPU reads return 0/FFFF → game logic bugs (AI, paths, collision).
// Range:
//   $274000-$275FFF (pf1, 8 KB = 4096 words)
//   $276000-$277FFF (pf2, 8 KB = 4096 words)
// =====================================================================
// POCKET: no separate mirror RAM; the CPU reads back from port A of the deco16ic
// VRAM (same content: same writes), see deco16ic_jt.sv.
// is_pf1 = chip1 range. Bit [13] tells pf1 (0) from pf2 (1) — see
// is_pf1_data/is_pf2_data in deco16ic_jt (cpu_addr[15:13] == 010 / 011).
wire c1_is_pf1_data = is_pf1 && (cpu_addr[15:13] == 3'b010);
wire c1_is_pf2_data = is_pf1 && (cpu_addr[15:13] == 3'b011);
wire [11:0] c1_mirror_idx = cpu_addr[12:1];

// Savestate adaptors in series on the chip1 mirror ports (NO extra BRAM).
wire c1m1_we_lo_cpu = c1_is_pf1_data && cpu_wr && ~cpu_dsn[0];
wire c1m1_we_hi_cpu = c1_is_pf1_data && cpu_wr && ~cpu_dsn[1];
wire c1m2_we_lo_cpu = c1_is_pf2_data && cpu_wr && ~cpu_dsn[0];
wire c1m2_we_hi_cpu = c1_is_pf2_data && cpu_wr && ~cpu_dsn[1];
wire c1m1_we_lo, c1m1_we_hi, c1m2_we_lo, c1m2_we_hi;
wire [11:0] c1m1_idx, c1m2_idx;
wire [15:0] c1m1_wdata_eff, c1m2_wdata_eff;
ss_ram16_adaptor #(.WIDTHAD(12), .SS_IDX(SS_IDX_C1_PF1_MIR)) c1m1_ss (
	.clk(clk),
	.we_lo_in(c1m1_we_lo_cpu), .we_hi_in(c1m1_we_hi_cpu), .addr_in(c1_mirror_idx), .wdata_in(cpu_wdata),
	.we_lo_out(c1m1_we_lo), .we_hi_out(c1m1_we_hi), .addr_out(c1m1_idx), .wdata_out(c1m1_wdata_eff),
	.q_in(c1_pf1_mirror_rd), .ssbus(ssb[SS_IDX_C1_PF1_MIR])
);
ss_ram16_adaptor #(.WIDTHAD(12), .SS_IDX(SS_IDX_C1_PF2_MIR)) c1m2_ss (
	.clk(clk),
	.we_lo_in(c1m2_we_lo_cpu), .we_hi_in(c1m2_we_hi_cpu), .addr_in(c1_mirror_idx), .wdata_in(cpu_wdata),
	.we_lo_out(c1m2_we_lo), .we_hi_out(c1m2_we_hi), .addr_out(c1m2_idx), .wdata_out(c1m2_wdata_eff),
	.q_in(c1_pf2_mirror_rd), .ssbus(ssb[SS_IDX_C1_PF2_MIR])
);
reg c1_pf1_rd_d, c1_pf2_rd_d;
always @(posedge clk) begin
	c1_pf1_rd_d <= c1_is_pf1_data;
	c1_pf2_rd_d <= c1_is_pf2_data;
end
wire [15:0] c1_pf1_mirror_rd, c1_pf2_mirror_rd;   // port A of the u_deco16_1 VRAM
wire [15:0] c1_mirror_rdata  = c1_pf2_rd_d ? c1_pf2_mirror_rd :
                                c1_pf1_rd_d ? c1_pf1_mirror_rd :
                                d16_1_cpu_rdata;

// =====================================================================
// Chip0 VRAM shadow mirror (same scheme as chip1 above).
// The deco16ic_jt cpu_rdata mux does NOT serve is_pf1_data/is_pf2_data,
// so without this path chip0 VRAM data reads ($264000/$266000) return 0x0000.
// The routine at 0x16AFC does read-modify-write on the YES/NO glyphs (BG0): reading 0
// clears the tile codes -> invisible text. "1P" survives (rewritten plainly).
// Range: $264000-$265FFF (pf1, [15:13]==010) / $266000-$267FFF (pf2, ==011).
// Gated on is_pf0 (NOT is_pf0_mirror=$24Cxxx, which is the ctrl remap).
// =====================================================================
wire c0_is_pf1_data = is_pf0 && (cpu_addr[15:13] == 3'b010);
wire c0_is_pf2_data = is_pf0 && (cpu_addr[15:13] == 3'b011);
wire [11:0] c0_mirror_idx = cpu_addr[12:1];
wire c0m1_we_lo_cpu = c0_is_pf1_data && cpu_wr && ~cpu_dsn[0];
wire c0m1_we_hi_cpu = c0_is_pf1_data && cpu_wr && ~cpu_dsn[1];
wire c0m2_we_lo_cpu = c0_is_pf2_data && cpu_wr && ~cpu_dsn[0];
wire c0m2_we_hi_cpu = c0_is_pf2_data && cpu_wr && ~cpu_dsn[1];
wire c0m1_we_lo, c0m1_we_hi, c0m2_we_lo, c0m2_we_hi;
wire [11:0] c0m1_idx, c0m2_idx;
wire [15:0] c0m1_wdata_eff, c0m2_wdata_eff;
wire [15:0] c0_pf1_mirror_rd, c0_pf2_mirror_rd;
ss_ram16_adaptor #(.WIDTHAD(12), .SS_IDX(SS_IDX_C0_PF1_MIR)) c0m1_ss (
	.clk(clk),
	.we_lo_in(c0m1_we_lo_cpu), .we_hi_in(c0m1_we_hi_cpu), .addr_in(c0_mirror_idx), .wdata_in(cpu_wdata),
	.we_lo_out(c0m1_we_lo), .we_hi_out(c0m1_we_hi), .addr_out(c0m1_idx), .wdata_out(c0m1_wdata_eff),
	.q_in(c0_pf1_mirror_rd), .ssbus(ssb[SS_IDX_C0_PF1_MIR])
);
ss_ram16_adaptor #(.WIDTHAD(12), .SS_IDX(SS_IDX_C0_PF2_MIR)) c0m2_ss (
	.clk(clk),
	.we_lo_in(c0m2_we_lo_cpu), .we_hi_in(c0m2_we_hi_cpu), .addr_in(c0_mirror_idx), .wdata_in(cpu_wdata),
	.we_lo_out(c0m2_we_lo), .we_hi_out(c0m2_we_hi), .addr_out(c0m2_idx), .wdata_out(c0m2_wdata_eff),
	.q_in(c0_pf2_mirror_rd), .ssbus(ssb[SS_IDX_C0_PF2_MIR])
);
reg c0_pf1_rd_d, c0_pf2_rd_d;
always @(posedge clk) begin
	c0_pf1_rd_d <= c0_is_pf1_data;
	c0_pf2_rd_d <= c0_is_pf2_data;
end
wire [15:0] c0_mirror_rdata  = c0_pf2_rd_d ? c0_pf2_mirror_rd :
                                c0_pf1_rd_d ? c0_pf1_mirror_rd :
                                d16_0_cpu_rdata;

// Palette is write-only from the 68K side: no palette readback (unmapped reads return FFFF)
assign cpu_rdata = is_rom         ? rom_plain       :
                    is_ram         ? ram_dout       :
                    is_spr1        ? spr1_cpu_rd    :
                    is_spr2        ? spr2_cpu_rd    :
                    is_ace         ? ace_cpu_rd     :
                    is_pf0         ? c0_mirror_rdata:
                    is_pf0_mirror  ? d16_0_cpu_rdata:
                    is_pf1         ? c1_mirror_rdata:
                    is_prot        ? prot_cpu_rd    :
                    16'hFFFF;
// cpu_dtackn is generated by jtframe_68kdtack_cen from bus_cs/bus_busy

// =====================================================================
// DECO104 protection / IO (rtl/common/deco104.sv, wrapper around deco146_base)
// =====================================================================
// Main CPU addresses (from the disassembly):
//   $24E138 → SYSTEM     (system_port)
//   $24E150 → soundlatch write (→ H6280 IRQ0)
//   $24E344 → INPUTS     (inputs_port)
//   $24E6C0 → DSW        (dsw_port)

wire  [7:0] sndlatch_data;
wire        sndlatch_irq_main_pulse;   // pulse: main CPU writes a new latch value
// DECO104 savestate: adaptor on the protection register bits (xor/nand/bank/latch/soundlatch).
wire [68:0] dc_ss_out, dc_ss_in;
wire        dc_ss_wr;
auto_save_adaptor #(.N_BITS(69), .SS_IDX(SS_IDX_DECO104)) u_deco104_ss_adaptor (
	.clk(clk), .ssbus(ssb[SS_IDX_DECO104]),
	.bits_in(dc_ss_out), .bits_out(dc_ss_in), .bits_wr(dc_ss_wr)
);
deco104 #(.SS_RB0_IDX(SS_IDX_DC_RB0), .SS_RB1_IDX(SS_IDX_DC_RB1)) u_prot (
	.clk             (clk),
	.reset           (reset),
	.cpu_addr        (cpu_addr[11:0]),  // offset relative to $24E000
	.cpu_cs          (is_prot),
	.cpu_rd          (cpu_rd),
	.cpu_wr          (cpu_wr),
	.cpu_wdata       (cpu_wdata),
	.cpu_dsn         (cpu_dsn),
	.cpu_rdata       (prot_cpu_rd),
	.port_a          (inputs_port),
	.port_b          (system_port),
	.port_c          (dsw_port),
	.soundlatch_data (sndlatch_data),
	.soundlatch_irq  (sndlatch_irq_main_pulse),
	.soundlatch_rd   (1'b0),             // unused: boogwings_audio keeps its own sndlatch FIFO
	.soundlatch_dout (),
	.dc_ss_in        (dc_ss_in),
	.dc_ss_out       (dc_ss_out),
	.dc_ss_wr        (dc_ss_wr),
	.ss_rb0          (ssb[SS_IDX_DC_RB0]),
	.ss_rb1          (ssb[SS_IDX_DC_RB1])
);

// =====================================================================
// Savestate: sprite DMA FSM + palette DMA FSM + priority_reg + irq6_pending (74 bit)
// =====================================================================
localparam integer MISC_SS_BITS = 74;
wire [MISC_SS_BITS-1:0] misc_ss_out, misc_ss_in;
wire                   misc_ss_wr;
auto_save_adaptor #(.N_BITS(MISC_SS_BITS), .SS_IDX(SS_IDX_MISC)) u_misc_ss_adaptor (
	.clk     (clk),
	.ssbus   (ssb[SS_IDX_MISC]),
	.bits_in (misc_ss_out),
	.bits_out(misc_ss_in),
	.bits_wr (misc_ss_wr)
);
// SAVE: concatenated in order (save and restore use the identical order)
//  [73:58] priority_reg  [57] irq6_pending  [56:46] dma_rd_idx  [45:36] dma_wr_idx  [35] dma_which
//  [34] dma2_active  [33] dma1_active  [32] pal_dma_active  [31:19] pal_dma_rd_idx  [18:8] pal_dma_wr_idx
//  [7:0] pal_dma_b_lat
assign misc_ss_out = {priority_reg, irq6_pending, dma_rd_idx, dma_wr_idx, dma_which, dma2_active, dma1_active,
                      pal_dma_active, pal_dma_rd_idx, pal_dma_wr_idx, pal_dma_b_lat};
// RESTORE: extracted in the same order (same endianness as the save)
wire [15:0] misc_priority_load        = misc_ss_in[73:58];
wire        misc_irq6_load            = misc_ss_in[57];
wire [10:0] misc_dma_rd_idx_load      = misc_ss_in[56:46];
wire [9:0]  misc_dma_wr_idx_load      = misc_ss_in[45:36];
wire        misc_dma_which_load       = misc_ss_in[35];
wire        misc_dma2_load            = misc_ss_in[34];
wire        misc_dma1_load            = misc_ss_in[33];
wire        misc_pal_dma_active_load  = misc_ss_in[32];
wire [12:0] misc_pal_dma_rd_idx_load  = misc_ss_in[31:19];
wire [10:0] misc_pal_dma_wr_idx_load  = misc_ss_in[18:8];
wire [7:0]  misc_pal_dma_b_lat_load   = misc_ss_in[7:0];

// =====================================================================
// Priority register (0x220000) — written by the CPU, used by the video mixer
// =====================================================================
reg [15:0] priority_reg;
always @(posedge clk) begin
	if (reset) priority_reg <= 16'd0;
	else if (is_prio & cpu_wr) begin
		if (~cpu_dsn[0]) priority_reg[7:0]  <= cpu_wdata[7:0];
		if (~cpu_dsn[1]) priority_reg[15:8] <= cpu_wdata[15:8];
	end
	else if (misc_ss_wr) priority_reg <= misc_priority_load;   // restore (transparent with SS idle)
end

// =====================================================================
// SOUND CPU H6280 @ 8.055 MHz (32.22/4)
// =====================================================================
// HUC6280 + Boogie Wings audio memory map: in boogwings_audio.sv (u_audio below)
//   - ROM 64KB (BRAM)
//   - YM2151 @ 0x110000
//   - OKIM6295 #1 @ 0x120000
//   - OKIM6295 #2 @ 0x130000
//   - soundlatch @ 0x140000 (from DECO104)
//   - IRQ0 = soundlatch_irq_cb, IRQ2 = YM2151 IRQ
//   - RAM 8KB @ 0x1F0000

// =====================================================================
// DECO16IC × 2 (tilemap engine, 4 BG layers in total)
// =====================================================================
// Tilegen[0]: pf1+pf2 (BG 1+2), CS @ 0x260000-0x26AFFF
// Tilegen[1]: pf1+pf2 (BG 3+4), CS @ 0x270000-0x27AFFF
// Tile ROMs come from SDRAM (see the tile ROM sections below)
wire [3:0]  d16_0_pf1_pix;
wire [4:0]  d16_0_pf2_pix;     // 5-bit for BG1 5bpp (Boogie Wings)
wire [4:0]  d16_0_pf1_col,  d16_0_pf2_col;
wire        d16_0_pf1_opq,  d16_0_pf2_opq;
wire        flip_screen;        // chip0 ctrl[0] bit 7 (MAME boogwing.cpp:419)
// Render x/y flipped when flip_screen=1 (MAME flip_screen_set). Only for the
// TILEGENs: the sprites get the raw coordinates and flip by themselves.
// Boogie Wings screen: hcnt 0..441, active 0..319 → x flip = 319-x.
// Template.sv: render_x=hcnt (= MAME x), render_y=vcnt+1 (the whole picture
// raised by 1 px). In MAME the vertical mirror axis is 255; in the space
// raised by 1 it becomes 255+2*1 = 257, not 255. With flip, the sprites,
// which internally use the MAME constants (240-y, 304-x), land exactly
// on axis 257.
wire [9:0] render_x_flip = flip_screen ? (10'd319 - render_x) : render_x;
wire [9:0] render_y_flip = flip_screen ? (10'd257 - render_y) : render_y;
wire [3:0]  d16_1_pf1_pix;
wire [4:0]  d16_1_pf2_pix;     // 5-bit interface but 4bpp (bit 4 always 0)
wire [4:0]  d16_1_pf1_col,  d16_1_pf2_col;
wire        d16_1_pf1_opq,  d16_1_pf2_opq;
wire [23:0] d16_0_pf1_rom_addr, d16_0_pf2_rom_addr;
wire [2:0]  d16_0_pf1_rid, d16_0_pf2_rid;
wire        d16_0_pf1_rom_req,  d16_0_pf2_rom_req;
wire [31:0] d16_0_pf1_rom_data, d16_0_pf2_rom_data;
wire        d16_0_pf1_rom_valid,d16_0_pf2_rom_valid;
wire        d16_0_pf2_p4_req;
wire  [7:0] d16_0_pf2_p4_data;
wire        d16_0_pf2_p4_valid;
wire [23:0] d16_1_pf1_rom_addr, d16_1_pf2_rom_addr;
wire [2:0]  d16_1_pf1_rid, d16_1_pf2_rid;
wire        d16_1_pf1_rom_req,  d16_1_pf2_rom_req;
wire [31:0] d16_1_pf1_rom_data, d16_1_pf2_rom_data;
wire        d16_1_pf1_rom_valid,d16_1_pf2_rom_valid;
// d16_0_cpu_rdata/d16_1_cpu_rdata already forward-declared above

// Boogie Wings bank callbacks (boogwing.cpp:749, 761):
//   tilegen[0]: bank1=none, bank2=bank_callback (mode 1)
//   tilegen[1]: bank1=bank_callback2, bank2=bank_callback2 (mode 2)
// GFX location in SDRAM (see sdram_bridge.sv):
//   tiles1 (text)  ba3 @ TXT_BASE              (128KB)
//   tiles2 (BG1)   ba3 @ TILES2_LO/MID/P4_BASE (3MB)
//   tiles3 (BG2)   ba0 + ba1 (duplicate) @ TILES3_LO_BASE (2MB)
// Mirror $24Cxxx: remaps the offset as a ctrl reg access (0x0000-0x000F)
// using cpu_addr[10:8] as the ctrl index. The main ROM (disasm 0xA94..0xABC)
// writes to $24C100,$24C200,$24C300,$24C400,$24C500,$24C600 = ctrl[0..6].
// A "virtual" cpu_addr is built and passed to the chip as a ctrl word.
wire [15:0] d16_0_cpu_addr_eff = is_pf0_mirror
    ? {12'd0, cpu_addr[10:8], 1'b0}  // maps to 0x0000-0x000E (8 ctrl words)
    : cpu_addr[15:0];

// Chip 0: pf1 = text 8x8 (tiles1), pf2 = BG1 16x16 (tiles2)
// Module: deco16ic_jt (scanline-based, inspired by Jotego's BAC06).
deco16ic_jt #(
	.BANK1_MODE(2'd0),
	.BANK2_MODE(2'd1),
	.PF1_COL_BANK(5'd0), .PF1_COL_MASK(4'hF),
	.PF2_COL_BANK(5'd0), .PF2_COL_MASK(4'hF),
	.PF1_TILE_SIZE(8),   .PF2_TILE_SIZE(16),
	.PF1_REGION_ID(3'd0),
	.PF2_REGION_ID(3'd2),
	// BG1 5bpp: chip0.pf2 also fetches plane 4 from TILES2_HI (= mbd-02).
	.PF2_HAS_5BPP(1),
	.PF2_REGION_ID_P4(3'd4),  // RID_TILES2_HI
	.SS_VRAM_PF1_IDX(SS_IDX_C0_VRAM_PF1),
	.SS_VRAM_PF2_IDX(SS_IDX_C0_VRAM_PF2),
	.SS_RS_PF1_IDX(SS_IDX_C0_RS_PF1),
	.SS_RS_PF2_IDX(SS_IDX_C0_RS_PF2),
	.SS_CTRL_IDX(SS_IDX_C0_CTRL)
) u_deco16_0 (
	.clk(clk), .reset(reset),
	.cpu_addr(d16_0_cpu_addr_eff),
	.cpu_cs(is_pf0 | is_pf0_mirror),
	.cpu_rd(cpu_rd), .cpu_wr(cpu_wr),
	.cpu_wdata(cpu_wdata), .cpu_dsn(cpu_dsn),
	.cpu_rdata(d16_0_cpu_rdata),
	.render_x(render_x_flip), .render_y(render_y_flip),
	.hblank_in(hblank_in), .vblank_in(vblank_in), .ce_pix(ce_pix),
	.pf1_pix(d16_0_pf1_pix), .pf2_pix(d16_0_pf2_pix),
	.pf1_col(d16_0_pf1_col), .pf2_col(d16_0_pf2_col),
	.pf1_opaque(d16_0_pf1_opq), .pf2_opaque(d16_0_pf2_opq),
	.flip_screen(flip_screen),
	.pf1_rom_addr(d16_0_pf1_rom_addr), .pf1_region_id(d16_0_pf1_rid),
	.pf1_rom_req(d16_0_pf1_rom_req),
	.pf1_rom_data(d16_0_pf1_rom_data), .pf1_rom_valid(d16_0_pf1_rom_valid),
	.pf2_rom_addr(d16_0_pf2_rom_addr), .pf2_region_id(d16_0_pf2_rid),
	.pf2_rom_req(d16_0_pf2_rom_req),
	.pf2_rom_data(d16_0_pf2_rom_data), .pf2_rom_valid(d16_0_pf2_rom_valid),
	.pf2_p4_req  (d16_0_pf2_p4_req),
	.pf2_p4_data (d16_0_pf2_p4_data),
	.pf2_p4_valid(d16_0_pf2_p4_valid),
	.osd_tile_decode_mode(osd_tile_decode_mode),
	.osd_pixel_bit_msb(osd_pixel_bit_msb),
	.osd_plane_rev32(osd_plane_rev32),
	.osd_nibble_swap(osd_nibble_swap),
	.osd_byte_swap_ab(osd_byte_swap_ab),
	.osd_xhalf_inv(osd_xhalf_inv),
	.osd_tile_hi_rev(osd_tile_hi_rev),
	.osd_vram_swizzle(osd_vram_swizzle),
	.osd_p4_byte_pos (osd_bg1_p4_byte_pos),
	.osd_p4_brev8    (osd_bg1_p4_brev8),
	.osd_p4_bit_shift(osd_bg1_p4_bit_shift),
	.ss_vram_pf1(ssb[SS_IDX_C0_VRAM_PF1]),
	.ss_vram_pf2(ssb[SS_IDX_C0_VRAM_PF2]),
	.ss_rs_pf1  (ssb[SS_IDX_C0_RS_PF1]),
	.ss_rs_pf2  (ssb[SS_IDX_C0_RS_PF2]),
	.ss_ctrl    (ssb[SS_IDX_C0_CTRL])
	,
	// Address from the mirror adaptor (CPU, or the mirror savestate during SAVE);
	// writes ONLY from the CPU: on LOAD the mirror slot data is the same as
	// the VRAM slot data, which is already written in its own turn (as in the original).
	.ext1_addr (c0m1_idx), .ext1_we_lo(c0m1_we_lo_cpu), .ext1_we_hi(c0m1_we_hi_cpu), .ext1_wdata(cpu_wdata),
	.pa1_q     (c0_pf1_mirror_rd),
	.ext2_addr (c0m2_idx), .ext2_we_lo(c0m2_we_lo_cpu), .ext2_we_hi(c0m2_we_hi_cpu), .ext2_wdata(cpu_wdata),
	.pa2_q     (c0_pf2_mirror_rd)
);

// Chip 1: pf1 + pf2 both BG2 16x16 (tiles3). pf2 col_bank=16.
deco16ic_jt #(
	.BANK1_MODE(2'd2),
	.BANK2_MODE(2'd2),
	.PF1_COL_BANK(5'd0),  .PF1_COL_MASK(4'hF),
	.PF2_COL_BANK(5'd16), .PF2_COL_MASK(4'hF),
	.PF1_TILE_SIZE(16),   .PF2_TILE_SIZE(16),
	.PF1_REGION_ID(3'd5),
	.PF2_REGION_ID(3'd5),
	.SS_VRAM_PF1_IDX(SS_IDX_C1_VRAM_PF1),
	.SS_VRAM_PF2_IDX(SS_IDX_C1_VRAM_PF2),
	.SS_RS_PF1_IDX(SS_IDX_C1_RS_PF1),
	.SS_RS_PF2_IDX(SS_IDX_C1_RS_PF2),
	.SS_CTRL_IDX(SS_IDX_C1_CTRL)
) u_deco16_1 (
	.clk(clk), .reset(reset),
	.cpu_addr(cpu_addr[15:0]),
	.cpu_cs(is_pf1),
	.cpu_rd(cpu_rd), .cpu_wr(cpu_wr),
	.cpu_wdata(cpu_wdata), .cpu_dsn(cpu_dsn),
	.cpu_rdata(d16_1_cpu_rdata),
	.render_x(render_x_flip), .render_y(render_y_flip),
	.hblank_in(hblank_in), .vblank_in(vblank_in), .ce_pix(ce_pix),
	.pf1_pix(d16_1_pf1_pix), .pf2_pix(d16_1_pf2_pix),
	.pf1_col(d16_1_pf1_col), .pf2_col(d16_1_pf2_col),
	.pf1_opaque(d16_1_pf1_opq), .pf2_opaque(d16_1_pf2_opq),
	.flip_screen(),
	.pf1_rom_addr(d16_1_pf1_rom_addr), .pf1_region_id(d16_1_pf1_rid),
	.pf1_rom_req(d16_1_pf1_rom_req),
	.pf1_rom_data(d16_1_pf1_rom_data), .pf1_rom_valid(d16_1_pf1_rom_valid),
	.pf2_rom_addr(d16_1_pf2_rom_addr), .pf2_region_id(d16_1_pf2_rid),
	.pf2_rom_req(d16_1_pf2_rom_req),
	.pf2_rom_data(d16_1_pf2_rom_data), .pf2_rom_valid(d16_1_pf2_rom_valid),
	.pf2_p4_req  (),       // chip1 no 5bpp
	.pf2_p4_data (8'd0),
	.pf2_p4_valid(1'b0),
	.osd_tile_decode_mode(osd_tile_decode_mode),
	.osd_pixel_bit_msb(osd_pixel_bit_msb),
	.osd_plane_rev32(osd_plane_rev32),
	.osd_nibble_swap(osd_nibble_swap),
	.osd_byte_swap_ab(osd_byte_swap_ab),
	.osd_xhalf_inv(osd_xhalf_inv),
	.osd_tile_hi_rev(osd_tile_hi_rev),
	.osd_vram_swizzle(osd_vram_swizzle),
	.osd_p4_byte_pos (2'd0),
	.osd_p4_brev8    (1'b0),
	.osd_p4_bit_shift(1'b0),
	.ss_vram_pf1(ssb[SS_IDX_C1_VRAM_PF1]),
	.ss_vram_pf2(ssb[SS_IDX_C1_VRAM_PF2]),
	.ss_rs_pf1  (ssb[SS_IDX_C1_RS_PF1]),
	.ss_rs_pf2  (ssb[SS_IDX_C1_RS_PF2]),
	.ss_ctrl    (ssb[SS_IDX_C1_CTRL])
	,
	// Address from the mirror adaptor (CPU, or the mirror savestate during SAVE);
	// writes ONLY from the CPU: on LOAD the mirror slot data is the same as
	// the VRAM slot data, which is already written in its own turn (as in the original).
	.ext1_addr (c1m1_idx), .ext1_we_lo(c1m1_we_lo_cpu), .ext1_we_hi(c1m1_we_hi_cpu), .ext1_wdata(cpu_wdata),
	.pa1_q     (c1_pf1_mirror_rd),
	.ext2_addr (c1m2_idx), .ext2_we_lo(c1m2_we_lo_cpu), .ext2_we_hi(c1m2_we_hi_cpu), .ext2_wdata(cpu_wdata),
	.pa2_q     (c1_pf2_mirror_rd)
);

// =====================================================================
// DECO_SPRITE × 2 (sprite engine)
// =====================================================================
// Sprite RAM 2KB each (0x242000-0x2427FF, 0x246000-0x2467FF)
// Double buffer: the CPU writes the live RAM, the DMA (at VBlank rise, see
// below) copies it into the buffer that feeds the renderer.
// Live (CPU rw + DMA read) → buf (renderer read).
// 2 BRAMs each, 2 ports each. Pipelined DMA:
//   - rd_idx: reads from the live RAM
//   - 1 ck later: writes into buf with index = rd_idx-1
//   - dma_active stays high for ~1025 cycles per chip (1024 reads + drain)
// Sprite RAM 2KB (1024×16) each. 8-bit lane split for clean M10K
// inference (1 CPU write port + 1 CPU readback port).
// CPU-side RAM (CPU rw + DMA read source)
(* ramstyle = "M10K", no_rw_check *) reg [7:0] spr1_lo [0:1023];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] spr1_hi [0:1023];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] spr2_lo [0:1023];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] spr2_hi [0:1023];
// Buffer side (DMA write dest + renderer read source) — buffered_spriteram MAME-style
(* ramstyle = "M10K", no_rw_check *) reg [7:0] spr1_buf_lo [0:1023];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] spr1_buf_hi [0:1023];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] spr2_buf_lo [0:1023];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] spr2_buf_hi [0:1023];
integer ii_spr;
initial for (ii_spr=0; ii_spr<1024; ii_spr=ii_spr+1) begin
	spr1_lo[ii_spr] = 8'd0; spr1_hi[ii_spr] = 8'd0;
	spr2_lo[ii_spr] = 8'd0; spr2_hi[ii_spr] = 8'd0;
	spr1_buf_lo[ii_spr] = 8'd0; spr1_buf_hi[ii_spr] = 8'd0;
	spr2_buf_lo[ii_spr] = 8'd0; spr2_buf_hi[ii_spr] = 8'd0;
end
wire [9:0] spr_idx = cpu_addr[10:1];

reg dma1_active, dma2_active;
reg [10:0] dma_rd_idx;          // 0..1025, DMA read index
wire dma_active = dma1_active | dma2_active;

// The 68K must not write sprite RAM during the DMA copy: that would corrupt
// the buffer mid-frame with a mix of old and new state.
wire spr1_we_lo_cpu = is_spr1 & cpu_wr & ~cpu_dsn[0] & ~dma_active;
wire spr1_we_hi_cpu = is_spr1 & cpu_wr & ~cpu_dsn[1] & ~dma_active;
wire spr2_we_lo_cpu = is_spr2 & cpu_wr & ~cpu_dsn[0] & ~dma_active;
wire spr2_we_hi_cpu = is_spr2 & cpu_wr & ~cpu_dsn[1] & ~dma_active;

// Savestate adaptors in series on the sprite CPU port (NO extra BRAM).
wire spr1_we_lo, spr1_we_hi, spr2_we_lo, spr2_we_hi;
wire [9:0]  spr1_idx, spr2_idx;
wire [15:0] spr1_wdata_eff, spr2_wdata_eff;
ss_ram16_adaptor #(.WIDTHAD(10), .SS_IDX(SS_IDX_SPR1)) spr1_ss (
	.clk(clk),
	.we_lo_in(spr1_we_lo_cpu), .we_hi_in(spr1_we_hi_cpu), .addr_in(spr_idx), .wdata_in(cpu_wdata),
	.we_lo_out(spr1_we_lo), .we_hi_out(spr1_we_hi), .addr_out(spr1_idx), .wdata_out(spr1_wdata_eff),
	.q_in(spr1_cpu_rd), .ssbus(ssb[SS_IDX_SPR1])
);
ss_ram16_adaptor #(.WIDTHAD(10), .SS_IDX(SS_IDX_SPR2)) spr2_ss (
	.clk(clk),
	.we_lo_in(spr2_we_lo_cpu), .we_hi_in(spr2_we_hi_cpu), .addr_in(spr_idx), .wdata_in(cpu_wdata),
	.we_lo_out(spr2_we_lo), .we_hi_out(spr2_we_hi), .addr_out(spr2_idx), .wdata_out(spr2_wdata_eff),
	.q_in(spr2_cpu_rd), .ssbus(ssb[SS_IDX_SPR2])
);

always @(posedge clk) if (spr1_we_lo) spr1_lo[spr1_idx] <= spr1_wdata_eff[ 7:0];
always @(posedge clk) if (spr1_we_hi) spr1_hi[spr1_idx] <= spr1_wdata_eff[15:8];
always @(posedge clk) if (spr2_we_lo) spr2_lo[spr2_idx] <= spr2_wdata_eff[ 7:0];
always @(posedge clk) if (spr2_we_hi) spr2_hi[spr2_idx] <= spr2_wdata_eff[15:8];

reg [7:0] spr1_rd_lo, spr1_rd_hi, spr2_rd_lo, spr2_rd_hi;
always @(posedge clk) spr1_rd_lo <= spr1_lo[spr1_idx];
always @(posedge clk) spr1_rd_hi <= spr1_hi[spr1_idx];
always @(posedge clk) spr2_rd_lo <= spr2_lo[spr2_idx];
always @(posedge clk) spr2_rd_hi <= spr2_hi[spr2_idx];
assign spr1_cpu_rd = {spr1_rd_hi, spr1_rd_lo};
assign spr2_cpu_rd = {spr2_rd_hi, spr2_rd_lo};

// Sprite renderer read port — reads from the BUFFER (= snapshot after the DMA).
// Reading the live CPU RAM would let Y/X change under the renderer -> jumping sprites.
wire [9:0]  spr_render_addr;
reg  [7:0]  spr1_rd_render_lo, spr1_rd_render_hi;
always @(posedge clk) spr1_rd_render_lo <= spr1_buf_lo[spr_render_addr];
always @(posedge clk) spr1_rd_render_hi <= spr1_buf_hi[spr_render_addr];
wire [15:0] spr_render_data = {spr1_rd_render_hi, spr1_rd_render_lo};

// Sprite chip1 (sprites2) renderer read port — buffer.
wire [9:0]  spr2_render_addr;
reg  [7:0]  spr2_rd_render_lo, spr2_rd_render_hi;
always @(posedge clk) spr2_rd_render_lo <= spr2_buf_lo[spr2_render_addr];
always @(posedge clk) spr2_rd_render_hi <= spr2_buf_hi[spr2_render_addr];
wire [15:0] spr2_render_data = {spr2_rd_render_hi, spr2_rd_render_lo};

// DMA controller: copy LIVE -> BUFFER at VBlank rise, both chips in sequence.
reg [9:0] dma_wr_idx;
reg dma_wr_en;
reg dma_which;
reg vblank_in_d;
always @(posedge clk) vblank_in_d <= vblank_in;
wire vblank_rise = vblank_in & ~vblank_in_d;

always @(posedge clk) begin
	if (reset) begin
		dma1_active <= 1'b0;
		dma2_active <= 1'b0;
		dma_rd_idx  <= 11'd0;
		dma_wr_idx  <= 10'd0;
		dma_wr_en   <= 1'b0;
		dma_which   <= 1'b0;
	end else if (misc_ss_wr) begin   // restore sprite DMA FSM (transparent with SS idle)
		dma1_active <= misc_dma1_load;
		dma2_active <= misc_dma2_load;
		dma_rd_idx  <= misc_dma_rd_idx_load;
		dma_wr_idx  <= misc_dma_wr_idx_load;
		dma_which   <= misc_dma_which_load;
	end else if (vblank_rise & ~paused_safe) begin
		// MAME buffered_spriteram16: copy LIVE -> BUFFER at VBlank rise (bufsprite.h).
		// Triggered here (NOT by cpu_wr to 0x240000, which is the first word of the live RAM).
		// Gated by ~paused_safe: during pause/SS the DMA does NOT run (consistent sprite buffer,
		// no copy mid-transition). After a restore it restarts at the 1st vblank -> rebuilds the buffer.
		dma1_active <= 1'b1;
		dma2_active <= 1'b1;
		dma_rd_idx  <= 11'd0;
		dma_wr_en   <= 1'b0;
		dma_which   <= 1'b0;
	end else if (dma_active) begin
		// Write index alignment (offset 1):
		//   - dma1_rd_lo_r in ck Y = spr1_lo[rd_idx_at_ck_(Y-1)]
		//   - the write event at posedge Y+1 uses the values of ck Y.
		//   - To write buf[K]<=spr1_lo[K]: rd_idx_Y-1=K (because dma1_rd_lo_r_Y=spr1_lo[K])
		//     AND wr_idx_Y=K. So wr_idx = rd_idx[K_prev] = K = (rd_idx_Y - 1 - 1)+1 = rd_idx_Y-1...
		//   - Equivalently: setting "wr_idx <= rd_idx_current" gives wr_idx_(Y+1)=rd_idx_Y.
		//   - For K: wr_idx in ck Y = K, dma1_rd_lo_r in ck Y = spr1_lo[K] (rd_idx_Y-1=K, rd_idx_Y=K+1).
		//   - wr_idx_Y = (assigned at posedge Y) = (rd_idx in ck Y-1) = K (because rd_idx_Y-1 = K).
		//   - So the formula is: wr_idx <= rd_idx[9:0]  (NO -1). Works for rd_idx 0..1023 (writes K=0..1023).
		// Loop up to 1025: rd_idx 0,1,...,1024,1025. Writes use rd_idx 0..1023 -> wr_idx_Y registered 1..1024 (=0 overflow ignored).
		if (dma_rd_idx == 11'd1025 && dma_which == 1'b1) begin
			dma1_active <= 1'b0;
			dma2_active <= 1'b0;
			dma_wr_en   <= 1'b0;
		end else if (dma_rd_idx == 11'd1025 && dma_which == 1'b0) begin
			dma_rd_idx  <= 11'd0;
			dma_which   <= 1'b1;
			dma_wr_en   <= 1'b0;
		end else begin
			dma_wr_en  <= (dma_rd_idx <= 11'd1023);
			dma_wr_idx <= dma_rd_idx[9:0];
			dma_rd_idx <= dma_rd_idx + 11'd1;
		end
	end else begin
		dma_wr_en <= 1'b0;
	end
end

// DMA read port: a dedicated read port addressed by dma_rd_idx reads the source RAM.
// 1 ck latency: the data is read in the ck after the address change -> dma_wr_idx = dma_rd_idx-1.
wire [9:0] dma_rd_addr = dma_rd_idx[9:0];
reg [7:0] dma1_rd_lo_r, dma1_rd_hi_r, dma2_rd_lo_r, dma2_rd_hi_r;
always @(posedge clk) dma1_rd_lo_r <= spr1_lo[dma_rd_addr];
always @(posedge clk) dma1_rd_hi_r <= spr1_hi[dma_rd_addr];
always @(posedge clk) dma2_rd_lo_r <= spr2_lo[dma_rd_addr];
always @(posedge clk) dma2_rd_hi_r <= spr2_hi[dma_rd_addr];

// DMA write port: writes into the buffer at index dma_wr_idx when dma_wr_en
always @(posedge clk) if (dma_wr_en && dma_which == 1'b0) spr1_buf_lo[dma_wr_idx] <= dma1_rd_lo_r;
always @(posedge clk) if (dma_wr_en && dma_which == 1'b0) spr1_buf_hi[dma_wr_idx] <= dma1_rd_hi_r;
always @(posedge clk) if (dma_wr_en && dma_which == 1'b1) spr2_buf_lo[dma_wr_idx] <= dma2_rd_lo_r;
always @(posedge clk) if (dma_wr_en && dma_which == 1'b1) spr2_buf_hi[dma_wr_idx] <= dma2_rd_hi_r;

// =====================================================================
// DECO_ACE (palette + alpha blend mixer)
// =====================================================================
// Palette RAM 8KB = 4096 colours × 16-bit. Double buffer (buffered_palette16):
// the CPU writes pal_cpu, the DMA on 0x282008 copies it into pal_buf, used by the mixer.
// ACE control register file: 0x3C0000-0x3C004F = 80 bytes (40 words) of
// alpha/blend configuration.
// Palette RAM 4096×16. pal_cpu (CPU rw + DMA read) → pal_buf (renderer read).
// 2 BRAMs, 2 ports each. 2-stage pipelined DMA (BRAM latency 1).
// Palette RAM 4096×16. 8-bit lane split. No CPU readback needed (write-only
// from the MAME boogwing point of view: the chip is a palette device, reading is
// debug only). The DMA always reads, CPU writes do not collide.
// Explicit palette BRAM init: without it some M10Ks start with garbage
// that the CPU never clears unless it writes the WHOLE palette at boot.
// DECO_ACE palette, 24-bit RGB888 (MAME deco_ace.cpp):
//   m_paletteram[2048] is uint32: bits 23:16 = B byte, 15:8 = G byte, 7:0 = R byte.
//   CPU word16 access: even offset → uint32[31:16] (= 0x00BB), odd → uint32[15:0] (= 0xGGRR).
//   $284000-$285FFF (8KB) = 4096 word16 = 2048 entries.
// no_rw_check: with concurrent CPU write + DMA read on pal_cpu_*, and concurrent
// DMA write + renderer read on pal_buf, the M10K mixed port must
// return the old value (no glitch). Without the attribute Quartus infers NEW_DATA
// = transient X output = flicker on the pixels rendered during the DMA.
(* ramstyle = "M10K", no_rw_check *) reg [7:0]  pal_cpu_lo [0:4095];
(* ramstyle = "M10K", no_rw_check *) reg [7:0]  pal_cpu_hi [0:4095];
// pal_buf duplicated: pal_buf_top for the top_pal_idx lookup, pal_buf_bot for bot_pal_idx.
// Allows 2 parallel reads without M10K port conflicts (max 2 ports: 1 DMA write + 1 read).
// The DMA writes both in parallel → identical content, no coherence issue.
(* ramstyle = "M10K", no_rw_check *) reg [23:0] pal_buf_top [0:2047];   // {B,G,R} 8-bit
(* ramstyle = "M10K", no_rw_check *) reg [23:0] pal_buf_bot [0:2047];
integer init_i;
initial begin
	for (init_i = 0; init_i < 4096; init_i = init_i + 1) begin
		pal_cpu_lo[init_i] = 8'd0;
		pal_cpu_hi[init_i] = 8'd0;
	end
	for (init_i = 0; init_i < 2048; init_i = init_i + 1) begin
		pal_buf_top[init_i] = 24'd0;
		pal_buf_bot[init_i] = 24'd0;
	end
end
wire [11:0] pal_idx = cpu_addr[12:1];

reg pal_dma_active;
reg [12:0] pal_dma_rd_idx;     // 0..4096 (reads 4096 CPU words = 2048 entries × 2)
reg [10:0] pal_dma_wr_idx;     // 0..2047 entry idx
reg        pal_dma_wr_en;
reg [7:0]  pal_dma_b_lat;      // B byte captured from the even word
reg [23:0] pal_dma_wr_data;    // data to write (latched together with wr_en)

wire pal_we_lo_cpu = is_pal & cpu_wr & ~cpu_dsn[0];
wire pal_we_hi_cpu = is_pal & cpu_wr & ~cpu_dsn[1];

// Savestate adaptor on the palette WRITE port (NO extra BRAM). During SS the
// game is paused (DMA stopped): the SS read uses the DMA port (pal_dma_rd_idx redirected
// to ssbus.addr) and q_in = pal_cpu_rd. With SS idle: transparent (pal_we=cpu, idx=pal_idx).
wire pal_we_lo, pal_we_hi;
wire [11:0] pal_idx_w;
wire [15:0] pal_wdata_eff;
wire        pal_ss_sel = ssb[SS_IDX_PAL_CPU].access(SS_IDX_PAL_CPU);
ss_ram16_adaptor #(.WIDTHAD(12), .SS_IDX(SS_IDX_PAL_CPU)) pal_ss (
	.clk(clk),
	.we_lo_in(pal_we_lo_cpu), .we_hi_in(pal_we_hi_cpu), .addr_in(pal_idx), .wdata_in(cpu_wdata),
	.we_lo_out(pal_we_lo), .we_hi_out(pal_we_hi), .addr_out(pal_idx_w), .wdata_out(pal_wdata_eff),
	.q_in(pal_cpu_rd), .ssbus(ssb[SS_IDX_PAL_CPU])
);
always @(posedge clk) if (pal_we_lo) pal_cpu_lo[pal_idx_w] <= pal_wdata_eff[ 7:0];
always @(posedge clk) if (pal_we_hi) pal_cpu_hi[pal_idx_w] <= pal_wdata_eff[15:8];

// DMA read port (BRAM lat=1). During SS the read is addressed by ssbus.addr (DMA stopped while paused).
wire [11:0] pal_rd_idx = pal_ss_sel ? ssb[SS_IDX_PAL_CPU].addr[11:0] : pal_dma_rd_idx[11:0];
reg [7:0] pal_dma_rd_lo, pal_dma_rd_hi;
always @(posedge clk) pal_dma_rd_lo <= pal_cpu_lo[pal_rd_idx];
always @(posedge clk) pal_dma_rd_hi <= pal_cpu_hi[pal_rd_idx];
wire [15:0] pal_cpu_rd = {pal_dma_rd_hi, pal_dma_rd_lo};

// DMA FSM:
//   rd_idx advances 0..4095 (reads all CPU words). Latency 1 ck.
//   When the data arrives (rd_idx+1 prev), if prev rd_idx[0]=0 → even word → byte B = pal_cpu_rd[7:0] into the latch.
//   When the data arrives and prev rd_idx[0]=1 → odd word → G=rd[15:8], R=rd[7:0] → compose + write.
//   pal_dma_wr_idx = (rd_idx_prev) >> 1.
reg pal_dma_rd_d0;   // rd_idx bit 0 delayed 1 ck (= tells B from GR when the data arrives)
reg pal_dma_rd_valid_d;  // a read was in progress in the previous ck
always @(posedge clk) begin
	if (reset) begin
		pal_dma_active   <= 1'b0;
		pal_dma_rd_idx   <= 13'd0;
		pal_dma_wr_idx   <= 11'd0;
		pal_dma_wr_en    <= 1'b0;
		pal_dma_b_lat    <= 8'd0;
		pal_dma_wr_data  <= 24'd0;
		pal_dma_rd_d0    <= 1'b0;
		pal_dma_rd_valid_d <= 1'b0;
	end else if (misc_ss_wr) begin   // restore palette DMA FSM (transparent with SS idle)
		pal_dma_active <= misc_pal_dma_active_load;
		pal_dma_rd_idx <= misc_pal_dma_rd_idx_load;
		pal_dma_wr_idx <= misc_pal_dma_wr_idx_load;
		pal_dma_b_lat  <= misc_pal_dma_b_lat_load;
	end else if ((is_paldma & cpu_wr) | ss_restore_done) begin
		// Palette DMA trigger: game command OR restore just finished (rebuilds pal_buf
		// from the reloaded pal_cpu -> consistent palette without saving pal_buf in the SS).
		pal_dma_active   <= 1'b1;
		pal_dma_rd_idx   <= 13'd0;
		pal_dma_wr_en    <= 1'b0;
		pal_dma_rd_valid_d <= 1'b0;
	end else if (pal_dma_active) begin
		// Default: no write this ck
		pal_dma_wr_en <= 1'b0;
		// Latch bit 0 + valid of the current read cycle (used at ck+1)
		pal_dma_rd_d0 <= pal_dma_rd_idx[0];
		pal_dma_rd_valid_d <= (pal_dma_rd_idx < 13'd4096);
		// When the data arrives (= read of the previous ck)
		if (pal_dma_rd_valid_d) begin
			if (!pal_dma_rd_d0) begin
				// word even = high uint32 = byte B
				pal_dma_b_lat <= pal_cpu_rd[7:0];
			end else begin
				// word odd = low uint32 = {G,R}. Composed and latched at once:
				// wr_en + wr_data take effect in the next ck, but by then
				// pal_cpu_rd belongs to the next word_idx (pipelined read).
				// So wr_data is captured NOW (together with wr_en).
				pal_dma_wr_en   <= 1'b1;
				pal_dma_wr_data <= {pal_dma_b_lat, pal_cpu_rd[15:8], pal_cpu_rd[7:0]};
				pal_dma_wr_idx  <= pal_dma_rd_idx[11:1] - 11'd1;
			end
		end
		// Advance rd_idx until done
		if (pal_dma_rd_idx == 13'd4096) begin
			pal_dma_active <= 1'b0;
		end else begin
			pal_dma_rd_idx <= pal_dma_rd_idx + 13'd1;
		end
	end else begin
		pal_dma_wr_en <= 1'b0;
		pal_dma_rd_valid_d <= 1'b0;
	end
end

// M10K inference: one always block per array, written separately.
always @(posedge clk) if (pal_dma_wr_en) pal_buf_top[pal_dma_wr_idx] <= pal_dma_wr_data;
always @(posedge clk) if (pal_dma_wr_en) pal_buf_bot[pal_dma_wr_idx] <= pal_dma_wr_data;

// ACE control register file (0x3C0000-0x3C004F = 40 words). Inferred as MLAB.
(* ramstyle = "MLAB" *) reg [15:0] ace_regs [0:63];
wire [5:0] ace_idx = cpu_addr[6:1];

// Savestate adaptor on ace_regs (blend/alpha/fade). Byte split lo/hi via dsn, like the palette.
// During SS (game paused) the write port is redirected to the ssbus; with SS idle: transparent.
wire        ace_we_lo_cpu = is_ace & cpu_wr & ~cpu_dsn[0];
wire        ace_we_hi_cpu = is_ace & cpu_wr & ~cpu_dsn[1];
wire        ace_we_lo, ace_we_hi;
wire [5:0]  ace_idx_w;
wire [15:0] ace_wdata_eff;
ss_ram16_adaptor #(.WIDTHAD(6), .SS_IDX(SS_IDX_ACE)) ace_ss (
	.clk(clk),
	.we_lo_in(ace_we_lo_cpu), .we_hi_in(ace_we_hi_cpu), .addr_in(ace_idx), .wdata_in(cpu_wdata),
	.we_lo_out(ace_we_lo), .we_hi_out(ace_we_hi), .addr_out(ace_idx_w), .wdata_out(ace_wdata_eff),
	.q_in(ace_cpu_rd), .ssbus(ssb[SS_IDX_ACE])
);
always @(posedge clk) begin
	if (ace_we_lo) ace_regs[ace_idx_w][7:0]  <= ace_wdata_eff[7:0];
	if (ace_we_hi) ace_regs[ace_idx_w][15:8] <= ace_wdata_eff[15:8];
end
reg [15:0] ace_cpu_rd_r;
// The SS read uses the read port: during SS the renderer is stopped and the idx is redirected.
wire [5:0] ace_rd_idx = ssb[SS_IDX_ACE].access(SS_IDX_ACE) ? ssb[SS_IDX_ACE].addr[5:0] : ace_idx;
always @(posedge clk) ace_cpu_rd_r <= ace_regs[ace_rd_idx];
assign ace_cpu_rd = ace_cpu_rd_r;

// The DECO_ACE alpha-blend pixel mixer is implemented below.

// =====================================================================
// DECO104PROT (I/O + protection): instantiated above (u_prot)
// =====================================================================
//   - Port A: INPUTS (p1+p2)
//   - Port B: SYSTEM (coin+start)
//   - Port C: DSW
//   - soundlatch_irq_cb → H6280 IRQ0
//   - interface_scramble_reverse + magic_read_address_xor

// =====================================================================
// YM2151 @ 3.58 MHz (32.22/9): jt51 in boogwings_audio.sv
// =====================================================================
// MAME reference:
//   - IRQ → H6280 IRQ2
//   - port_write → sound bankswitch
//   - mix 32% of the master volume

// =====================================================================
// OKIM6295 × 2: two jt6295 in boogwings_audio.sv
// =====================================================================
// MAME reference:
//   - OKI1 @ 1.007 MHz (32.22/32) PIN7_HIGH → mix 56%
//   - OKI2 @ 2.014 MHz (32.22/16) PIN7_HIGH → mix 12%
//   - Sample ROMs in DDRAM (ddram_4port read ports 5/6)

// =====================================================================
// VIDEO MIXER — 4 tile layers + 2 sprite chips
// =====================================================================
// Palette index base (boogwing.cpp:gfx_boogwing entries):
//   tiles1 (text 8×8)   = palette base 0x800
//   tiles2 (deco16_0)   = palette base 0x100
//   tiles3 (deco16_1)   = palette base 0x300
//
// pf1/pf2 of each chip use the same base (col_bank is applied outside):
//   deco16_0 pf*: base 0x100
//   deco16_1 pf*: base 0x300 / 0x300+16*16 for col_bank=16 (pf2)
//
// Palette index per layer (MAME gfx_boogwing boogwing.cpp:671):
//   tiles1 (text)  → base 0x800, 16 sets × 16 colours (4bpp)
//   tiles2 (BG1)   → base 0x100, 16 sets × 32 colours (5bpp)
//   tiles3 (BG2)   → base 0x300, 32 sets × 16 colours (4bpp)
// Formula: pal_idx = base + (set * Ncol) + pix
//   tiles1: pal_idx = 0x800 + col * 16 + pix
//   tiles2: pal_idx = 0x100 + col * 32 + pix
//   tiles3: pal_idx = 0x300 + col * 16 + pix
// Default priority, top → bottom (MAME boogwing.cpp:467-472 else case):
//   1. text       (chip0 pf1, palette 0x800)         ← TOP
//   2. BG1        (chip0 pf2, palette 0x100, tiles2)
//   3. BG2 alpha  (chip1 pf1, palette 0x300, tiles3)
//   4. BG2 base   (chip1 pf2, palette 0x300+16, tiles3, col_bank=16)
//   5. background
//
// MAME has 5 different modes via priority_reg[2:0] (see screen_update), all
// handled by the layer mixer below.
// (chip1 pf2 col_bank is already inside d16_1_pf2_col → not added here)
// Palette base per layer — MAME GFXDECODE (boogwing.cpp:672-674):
//   tiles1 text = 0x800, tiles2 BG1 = 0x100, tiles3 BG2 = 0x300.
// Fixed to the defaults verified on hardware.
wire [11:0] pal_bg0_base = 12'h800;
wire [11:0] pal_bg1_base = 12'h100;
wire [11:0] pal_bg2_base = 12'h300;
wire [11:0] pal_bg3_base = 12'h300;

// =====================================================================
// Layer mixer with MAME-compliant priority register (5 modes).
// Reference: boogwing.cpp:417-477 screen_update.
// =====================================================================
//
// Pixel components:
//   text  = chip0.pf1 (always TOP, drawn after the sprite mix)
//   bg1   = chip0.pf2
//   bg2a  = chip1.pf1 (BG2 alpha)
//   bg2b  = chip1.pf2 (BG2 base)
//   bg2c  = chip1 8bpp combine (pf1 low nibble + pf2 high nibble)
//
// priority[2:0] modes:
//   0/6/7 (default): bg2b (BOT) | bg2a (mid) | bg1 (top)        | text
//   1, 2           : bg2b (BOT) | bg1 (mid)  | bg2a (top)       | text
//   3              : like 1/2, bg2a as shadow (see mode 3 below) | text
//   4              : bg2c (BOT, combine)     | bg1 (top)        | text
//   5              : bg1  (BOT)              | bg2c (top combine)| text

wire [2:0] pri = priority_reg[2:0];
wire mode_combine = (pri == 3'd4) || (pri == 3'd5);
wire mode_bg2a_top = (pri == 3'd1) || (pri == 3'd2) || (pri == 3'd3);

wire mode_5       = (pri == 3'd5);

// BG2 combine (modes 4/5). chip1 is 4bpp: only [3:0] of pf2_pix is used.
wire [3:0]  bg2c_pen_hi = d16_1_pf2_opq ? d16_1_pf2_pix[3:0] : 4'd0;
wire        bg2c_opq    = d16_1_pf1_opq | d16_1_pf2_opq;
wire [11:0] bg2c_pal_pre = pal_bg2_base + {3'd0, d16_1_pf1_col, d16_1_pf1_pix};
wire [11:0] bg2c_pal_idx = {bg2c_pal_pre[11:8], bg2c_pal_pre[7:4] | bg2c_pen_hi, bg2c_pal_pre[3:0]};

// Per-layer pal_idx (for the non-combine modes)
wire [11:0] bg1_pal_idx  = pal_bg1_base + {2'd0, d16_0_pf2_col, 5'd0} + {8'd0, d16_0_pf2_pix};
wire [11:0] bg2a_pal_idx = pal_bg2_base + {3'd0, d16_1_pf1_col, d16_1_pf1_pix};
// chip1.pf2 is 4bpp (pen[3:0]). pf2_pix arrives as 5-bit but bit 4 is always 0.
// MAME formula: pal_idx = base + col_5b * 16 + pen[3:0].
wire [11:0] bg2b_pal_idx = pal_bg3_base + {3'd0, d16_1_pf2_col, d16_1_pf2_pix[3:0]};
wire [11:0] text_pal_idx = pal_bg0_base + {3'd0, d16_0_pf1_col, d16_0_pf1_pix};

// Forward declaration for ModelSim 10.5b (Quartus accepts inline forward use).
// The signals are actually driven below, near u_sprites.
wire [11:0] sprite_pxl;
// Chip1 leaves the renderer on TWO layers: opaque and transparent (smoke/explosions).
// They are kept separate so that the transparent pixel does not erase, in the buffer,
// the opaque one it covers: this way the blend has the real object underneath, not the
// background. See the comment on linebuf_spr1_a in bw_sprites.sv.
wire [11:0] sprite2_opq_pxl;
wire [11:0] sprite2_alp_pxl;
wire        spr2_alp_present = (sprite2_alp_pxl[3:0] != 4'd0);
// The chip1 pixel the mixer considers: the transparent one if present, otherwise the opaque one.
wire [11:0] sprite2_pxl = spr2_alp_present ? sprite2_alp_pxl : sprite2_opq_pxl;
// Opaque pixel of the SAME chip lying under the transparent one.
wire        spr2_under_opq = spr2_alp_present && (sprite2_opq_pxl[3:0] != 4'd0);
wire [11:0] spr2_under_pal_idx = 12'h700 + {3'd0, sprite2_opq_pxl[7:4], sprite2_opq_pxl[3:0]};

// Sprite chip0 (sprites1): MAME GFXDECODE 0x500, 32 banks x 16 colors.
// MAME mixer: pal_idx = 0x500 + (pix1 & 0x1ff) where pix1 = {color[7:0], pen[3:0]}
// → pal_idx = 0x500 + {color[4:0], pen[3:0]} (= 5-bit color = 32 banks)
wire [3:0]  spr_pen   = sprite_pxl[3:0];
wire [7:0]  spr_color = sprite_pxl[11:4];
// chip filter: 00=both, 01=chip0, 10=chip1, 11=none
wire chip0_visible = (osd_spr_chip_filter == 2'b00) || (osd_spr_chip_filter == 2'b01);
wire chip1_visible = (osd_spr_chip_filter == 2'b00) || (osd_spr_chip_filter == 2'b10);
wire        spr_opq   = (spr_pen != 4'd0);
wire [11:0] spr_pal_idx = 12'h500 + {2'd0, spr_color[4:0], spr_pen};

// Sprite chip1 (sprites2): MAME 0x700, 16 banks x 16 colors.
// pal_idx = 0x700 + {color[3:0], pen[3:0]} (= 4-bit color = 16 banks).
wire [3:0]  spr2_pen   = sprite2_pxl[3:0];
wire [7:0]  spr2_color = sprite2_pxl[11:4];
wire        spr2_opq   = (spr2_pen != 4'd0);
wire [11:0] spr2_pal_idx = 12'h700 + {3'd0, spr2_color[3:0], spr2_pen};

// MAME boogwing.cpp mix(): dynamic sprite vs sprite priority (pixel by pixel).
// pri bits = bits 9,10 of the raw pixel = color[5], color[6] here (= x_word[14], x_word[15]).
// MAME (priority_reg & 0x7) default case → spri1 = 2/8/32, spri2 = 4/16/64.
// pri_bits = {color[6], color[5]} = {x_bit15, x_bit14}
// MAME spri1: 0x600=0b11 → 2 ; 0x400=0b10 → 8 ; else → 32
// MAME spri2: 0x600=0b11 → 4 ; (0x400 OR 0x200)=non-zero → 16 ; else → 64
wire [1:0] spr_pri  = {spr_color[6],  spr_color[5]};   // chip0 pri bits
wire [1:0] spr2_pri = {spr2_color[6], spr2_color[5]};  // chip1 pri bits

// MAME spri1 (boogwing.cpp:240-262) has a CASE on priority:
//   case 0x00: (pix1&0x600)==0x600 -> 2 ; ==0x400 -> 8 ; else -> 32
//   default (priority!=0): (pix1&0x400) -> 8 ; else -> 32   (NEVER 2!)
// The case must be honoured: in priority 4 (pre-boss cutscene, the text is a chip0
// sprite) the 0x00 scheme would give spri1=2 when spr_pri=2'b11, while MAME gives spri1=8.
// With spri1 too low, chip1_over_chip0=(spri2>spri1) fires and the text (chip0) gets
// covered by chip1 -> invisible cutscene text.
reg [6:0] spri1, spri2;
always @(*) begin
	if (pri == 3'd0) begin
		case (spr_pri)
			2'b11:   spri1 = 7'd2;
			2'b10:   spri1 = 7'd8;
			default: spri1 = 7'd32;
		endcase
	end else begin
		spri1 = spr_pri[1] ? 7'd8 : 7'd32;   // MAME default: (pix1 & 0x400) ? 8 : 32
	end
	case (spr2_pri)
		2'b11:                spri2 = 7'd4;
		2'b10, 2'b01:         spri2 = 7'd16;
		default:              spri2 = 7'd64;
	endcase
end

// chip1 above chip0 if spri2 > spri1 (MAME default).
//
// EXCEPTION from the board's priority PROM (kj-00.15n, mode 0 block;
// the game ALSO uses other modes and bit 3 - end of level, boss - so this
// exception applies only when priority_reg[2:0] == 0).
// With both sprites in front (bit10 = 0 on both) the table says
// "both are visible", EXCEPT when pix1 bit9 = 0 and pix2 bit9 = 1.
// MAME instead computes spri1 = 32 (because p1 in {0,1} ends in the else branch) and
// spri2 = 16 (because p2 = 1 enters "else if (pix2 & 0x600)"): with bit9 = 1 on
// both, the condition spri2 > spri1 is false and the chip 1 pixel is
// discarded. On the board that pixel is visible.
wire prom0_both_front  = (pri == 3'd0) && !spr_pri[1] && !spr2_pri[1];
wire prom0_chip0_alone = ~spr_pri[0] & spr2_pri[0];
wire chip1_over_chip0  = prom0_both_front ? ~prom0_chip0_alone : (spri2 > spri1);

// === MAME priority bitmap (bg_pri) for sprite vs playfield ===
// MAME boogwing.cpp:437-471: after screen.priority().fill(0), each tilemap_draw
// passes a priority_value that is written into the priority bitmap for the opaque
// pixels drawn. Then mix() compares pri1/pri2 (sprite) > bgpri to decide.
//
// MAME draw sequence (pri_reg & 0x7):
//   case 0x5: PF2[0] OPAQUE=0, combine[1] pri=32
//   case 0x4: combine[1] OPAQUE=0, PF2[0] pri=32
//   case 0x1/0x2: PF2[1] OPAQUE=0, PF2[0] pri=8, PF1[1] pri=32
//   case 0x3: PF2[1] OPAQUE=0, PF2[0] pri=8, PF1[1] alpha (NO priority write)
//   default (0,6,7): PF2[1] OPAQUE=0, PF1[1] pri=8, PF2[0] pri=32
//
// RTL name mapping:
//   PF2[0] = d16_0_pf2 = BG1
//   PF1[1] = d16_1_pf1 = FG0 (BG2 alpha tmap)
//   PF2[1] = d16_1_pf2 = FG1 (BG2 base)
//   combine[1] = bg2c (= FG0|FG1 combined)
//
// bg_pri is updated in draw order: the last opaque layer drawn overwrites it.
// Equivalent: scan in reverse and take the first opaque one.
reg [6:0] bg_pri;
always @(*) begin
	bg_pri = 7'd0;
	case (pri)
		3'd5: begin
			if      (bg2c_opq)         bg_pri = 7'd32;  // combine (drawn last)
			else if (d16_0_pf2_opq)    bg_pri = 7'd0;   // BG1 opaque
		end
		3'd4: begin
			if      (d16_0_pf2_opq)    bg_pri = 7'd32;  // BG1 (drawn last)
			else if (bg2c_opq)         bg_pri = 7'd0;   // combine opaque
		end
		3'd1, 3'd2: begin
			if      (d16_1_pf1_opq)    bg_pri = 7'd32;  // FG0 (drawn last)
			else if (d16_0_pf2_opq)    bg_pri = 7'd8;   // BG1
			else if (d16_1_pf2_opq)    bg_pri = 7'd0;   // FG1 opaque
		end
		3'd3: begin
			// FG0 in mode 3 = alpha tmap, NO priority write
			if      (d16_0_pf2_opq)    bg_pri = 7'd8;   // BG1
			else if (d16_1_pf2_opq)    bg_pri = 7'd0;   // FG1 opaque
		end
		default: begin // 0, 6, 7
			if      (d16_0_pf2_opq)    bg_pri = 7'd32;  // BG1 (drawn last)
			else if (d16_1_pf1_opq)    bg_pri = 7'd8;   // FG0
			else if (d16_1_pf2_opq)    bg_pri = 7'd0;   // FG1 opaque
		end
	endcase
end

// pri1 = sprite chip0 priority vs playfield (MAME boogwing.cpp:264-295)
// pri2 = sprite chip1 priority vs playfield (MAME boogwing.cpp:316-338)
// IMPORTANT: MAME checks like "(pix & 0x400) == 0x400" test ONLY bit 10
// (= spr_pri[1]), NOT the exact pattern 2'b10. So spr_pri=2'b11 satisfies them too.
reg [6:0] pri1, pri2;
always @(*) begin
	// pri1
	case (pri)
		3'd1: pri1 = (spr_pri != 2'b00)       ? 7'd16 : 7'd64;
		3'd0: pri1 = spr_pri[1]               ? 7'd16 : 7'd64;
		default: begin
			if      (spr_pri == 2'b11)        pri1 = 7'd4;
			else if (spr_pri[1])              pri1 = 7'd16;
			else                              pri1 = 7'd64;
		end
	endcase
	// pri2
	case (pri)
		3'd2: begin
			if      (spr2_pri == 2'b11)       pri2 = 7'd4;
			else if (spr2_pri[1])             pri2 = 7'd16;
			else                              pri2 = 7'd64;
		end
		3'd3:    pri2 = spr2_pri[1]            ? 7'd16 : 7'd64;
		default: pri2 = spr2_pri[1]            ? 7'd16 : 7'd64;
	endcase
end

// Sprite vs playfield: visible only if pri > bg_pri (MAME mix() lines 359/371)
wire spr0_above_bg  = (pri1 > bg_pri);
wire spr1_above_bg  = (pri2 > bg_pri);

// MAME drawnpixe1 flags (mix() lines 357-387): sprite pixel ACTUALLY drawn
wire chip0_drawn = layer_spr_en && chip0_visible && spr_opq && spr0_above_bg;
wire chip1_drawn = layer_spr_en && chip1_visible && spr2_opq && spr1_above_bg
                   && (chip1_over_chip0 || !chip0_drawn);

// MODE 3 shadow apply (MAME line 396-411):
//   pri3 = 32. Condition: bg2_drawed (= bgpri==8 && no sprite) OR
//   (sprite_drawn && pri_sprite <= pri3=32).
//   Then the filter: ((pix2 & 0x900) != 0x900) || ((spri2 <= spri1) && sprite1_drawed)
//   pix2 bit 11 = spr2_color[7], bit 8 = spr2_color[4]. & 0x900 == 0x900 → both set.
wire mode3_bg2_drawed = (bg_pri == 7'd8) && !chip0_drawn && !chip1_drawn;
wire mode3_sprite1_drawed = chip0_drawn && (pri1 <= 7'd32);
wire mode3_sprite2_drawed = chip1_drawn && (pri2 <= 7'd32);
wire mode3_pix2_900       = spr2_color[7] && spr2_color[4];  // pix2 & 0x900 == 0x900
wire mode3_filter_pass    = !mode3_pix2_900 || ((spri2 <= spri1) && mode3_sprite1_drawed);
wire mode3_shadow_apply   = (pri == 3'd3) && layer_fg0_en && d16_1_pf1_opq
                          && (mode3_bg2_drawed
                              || (mode3_sprite1_drawed && !(chip1_drawn))
                              || (mode3_sprite2_drawed && !(chip0_drawn))
                              || (mode3_sprite1_drawed && mode3_sprite2_drawed))
                          && mode3_filter_pass;

// tmap_pal_idx = pixel of the highest opaque BG layer at the current pixel.
// MAME mix() line 369: dstline[x] = paldata[tmappix] (= last tilemap drawn).
// Used as "underneath" when sprite chip1 alpha-blends, to see the BG through it.
// BACKDROP: where all layers are transparent, MAME shows pen 0x400 (boogwing.cpp:435
// bitmap.fill(pen(0x400))), NOT pen 0 (black). Without the backdrop, a blend over the open
// sky mixes with black -> BLACK BLOTCHES. Fallback = backdrop, not 12'd0.
localparam [11:0] PAL_BACKDROP = 12'h400;
reg [11:0] tmap_pal_idx;
always @(*) begin
	case (pri)
		3'd5: begin
			if      (bg2c_opq)         tmap_pal_idx = bg2c_pal_idx;     // combine, drawn last
			else if (d16_0_pf2_opq)    tmap_pal_idx = bg1_pal_idx;      // BG1
			else                       tmap_pal_idx = PAL_BACKDROP;
		end
		3'd4: begin
			if      (d16_0_pf2_opq)    tmap_pal_idx = bg1_pal_idx;      // BG1, drawn last
			else if (bg2c_opq)         tmap_pal_idx = bg2c_pal_idx;
			else                       tmap_pal_idx = PAL_BACKDROP;
		end
		3'd1, 3'd2: begin
			if      (d16_1_pf1_opq)    tmap_pal_idx = bg2a_pal_idx;     // FG0, drawn last
			else if (d16_0_pf2_opq)    tmap_pal_idx = bg1_pal_idx;      // BG1
			else if (d16_1_pf2_opq)    tmap_pal_idx = bg2b_pal_idx;     // FG1
			else                       tmap_pal_idx = PAL_BACKDROP;
		end
		3'd3: begin
			if      (d16_0_pf2_opq)    tmap_pal_idx = bg1_pal_idx;
			else if (d16_1_pf2_opq)    tmap_pal_idx = bg2b_pal_idx;
			else                       tmap_pal_idx = PAL_BACKDROP;
		end
		default: begin // 0, 6, 7
			if      (d16_0_pf2_opq)    tmap_pal_idx = bg1_pal_idx;      // BG1, drawn last
			else if (d16_1_pf1_opq)    tmap_pal_idx = bg2a_pal_idx;
			else if (d16_1_pf2_opq)    tmap_pal_idx = bg2b_pal_idx;
			else                       tmap_pal_idx = PAL_BACKDROP;
		end
	endcase
end

// === Sprite chip1 alpha-blend (MAME boogwing.cpp:305-314) ===
// pix2 = (colour << 4) | pen → mapping to the signals here:
//   pix2[3:0]   = spr2_pen[3:0]
//   pix2[7:4]   = spr2_color[3:0]  (= the 4 colour LSBs visible in pal_idx)
//   pix2[8]     = spr2_color[4]    (= x_word bit 13)
//   pix2[11]    = spr2_color[7]    (= y_word bit 15)
//   pix2 & 0x80 = spr2_color[3]    (= colour bit 3 = x_word bit 12)
//   pix2 & 8    = spr2_pen[3]      (= pen MSB)
//
// MAME alpha2 logic:
//   default: alpha2 = get_alpha((pix2 >> 4) & 0xf)  = get_alpha(spr2_color[3:0])
//   if pix2[8]:
//      if pix2[11]: alpha2 = (pix2&8) ? 0xff : get_alpha(0x14 + ((pix2-1) & 0x7))
//      else:        alpha2 = get_alpha(0x10 + (pix2[7] ? 1 : 0))
//   else if pix2[11]: alpha2 = get_alpha(0x12 + (pix2[7] ? 1 : 0))
//
// MAME get_alpha(N): regval = ace_regs[N][7:0];
//   if regval > 0x20: return 0x80 (special)
//   else: return clamp_unsigned(255 - (regval << 3))
//
// When alpha2 < 0xff → blend the sprite with the layer underneath.
function [7:0] ace_alpha_of(input [7:0] regval);
	reg [10:0] sh, sub;
	begin
		sh  = {3'd0, regval} << 3;
		sub = 11'd255 - sh;
		ace_alpha_of = (regval > 8'h20) ? 8'h80
		             : (sub[10] ? 8'd0 : sub[7:0]);
	end
endfunction

wire pix2_bit8  = spr2_color[4];
wire pix2_bit11 = spr2_color[7];
wire pix2_bit7  = spr2_color[3];
wire pix2_bit3  = spr2_pen[3];
// pix2[2:0] = pen[2:0] → "(pix2 - 1) & 0x7" on 8 bits, but used only for LUT 0x14..0x1b
wire [2:0] pix2_minus1_low3 = {spr2_pen[2:0]} - 3'd1;

reg [5:0] alpha_idx_r;
reg       alpha_is_const_ff;
always @(*) begin
	alpha_is_const_ff = 1'b0;
	alpha_idx_r = {2'd0, spr2_color[3:0]};   // default: get_alpha(pix2>>4 & 0xf)
	if (pix2_bit8) begin
		if (pix2_bit11) begin
			// boogwing.cpp:309 makes the pixel opaque when pen bit 3 is set, without
			// reading the ACE LUT. This is required, not an emulator shortcut: without it
			// the explosions turn brownish and transparent where MAME shows them solid
			// and bright. (Objects disappearing under smoke are a matter of priority
			// between the two sprite chips, not of this alpha rule.)
			if (pix2_bit3) begin
				alpha_is_const_ff = 1'b1;     // alpha2 = 0xff (opaque)
			end else begin
				alpha_idx_r = 6'h14 + {3'd0, pix2_minus1_low3};
			end
		end else begin
			alpha_idx_r = 6'h10 + {5'd0, pix2_bit7};
		end
	end else if (pix2_bit11) begin
		alpha_idx_r = 6'h12 + {5'd0, pix2_bit7};
	end
end

wire [7:0] spr2_alpha = alpha_is_const_ff ? 8'hff
                      : ace_alpha_of(ace_regs[alpha_idx_r][7:0]);
wire       spr2_blend = (spr2_alpha < 8'hff);

// layer_fg0_en = chip1.pf1 (BG2 alpha), layer_fg1_en = chip1.pf2 (BG2 base).
// Priority: text > sprite > BG/FG layers.
//
// DECO_ACE alpha-blend (MAME deco_ace.cpp + boogwing.cpp mix()):
//   When priority_reg[2:0]==3 and FG0 (chip1.pf1) has pen != 0 → blend FG0 with the
//   layer underneath (usually BG1 or FG1). Alpha = 255 - (ace_regs[0x1f][4:0] << 3).
//   Chip1 sprites blend with what is underneath when their alpha2 < 0xff.
//   In all other cases normal opaque rendering.
//
// 2-index pipeline: top ("src" pixel) + bot ("dst" pixel). Separate BRAM lookup
// for each, then the blend in the following stages.
reg [11:0] top_pal_idx_r;
reg [11:0] bot_pal_idx_r;
reg        blend_en_r;       // 1 = blend top+bot, 0 = output top directly
reg        sub_blend_r;      // 1 = sub_blend (dst-src*alpha), 0 = alpha_blend lerp
reg [7:0]  pixel_alpha_r;    // alpha factor for the current pixel (sprite chip1 or tmap)
always @(posedge clk) begin
	// default: no blend, alpha = tilemap default (= ace_regs[0x1f])
	blend_en_r    <= 1'b0;
	sub_blend_r   <= 1'b0;
	bot_pal_idx_r <= PAL_BACKDROP;   // dst default = backdrop (not black) for blends over the sky
	pixel_alpha_r <= ace_alpha;

	// Text always on TOP (drawn after the sprite mix in MAME).
	if (layer_bg0_en && d16_0_pf1_opq) begin
		top_pal_idx_r <= text_pal_idx;
	// DYNAMIC sprite priority pixel by pixel (MAME mix() spri1 vs spri2 + pri vs bg).
	// Sprite visible only if pri_sprite > bg_pri (sprite vs playfield).
	// If both are opaque: chip1 above chip0 if chip1_over_chip0 (= spri2 > spri1).
	// When chip1 wins AND has alpha2 < 0xff → blend chip1 with the layer underneath (= chip0 if
	// opaque AND chip0_above_bg, otherwise the BG selected below in the else branches).
	end else if (chip1_drawn) begin
		top_pal_idx_r <= spr2_pal_idx;
		if (spr2_blend) begin
			blend_en_r    <= 1'b1;
			// "Underneath" = in this order: the OPAQUE pixel of the same chip1 if present
			// (the power-up/elephant covered by smoke), then chip0 if visible,
			// finally the tmap layer (= the BG seen through).
			bot_pal_idx_r <= spr2_under_opq ? spr2_under_pal_idx
			               : chip0_drawn    ? spr_pal_idx
			                                : tmap_pal_idx;
			pixel_alpha_r <= spr2_alpha;
		end
		// Mode 3 shadow: src=shadow (top), dst=sprite (bot). sub_blend8(src,dst,a)=dst-src*a.
		if (mode3_shadow_apply) begin
			blend_en_r    <= 1'b1;
			sub_blend_r   <= (ace_regs[6'h1f][7:0] == 8'h22);
			top_pal_idx_r <= bg2a_pal_idx;     // src = shadow layer FG0
			bot_pal_idx_r <= spr2_pal_idx;     // dst = sprite chip1 underneath
			pixel_alpha_r <= ace_alpha;        // alpha3 = get_alpha(0x1f)
		end
	end else if (chip0_drawn) begin
		top_pal_idx_r <= spr_pal_idx;
		if (mode3_shadow_apply) begin
			blend_en_r    <= 1'b1;
			sub_blend_r   <= (ace_regs[6'h1f][7:0] == 8'h22);
			top_pal_idx_r <= bg2a_pal_idx;
			bot_pal_idx_r <= spr_pal_idx;
			pixel_alpha_r <= ace_alpha;
		end
	end else if (mode_combine) begin
		// Mode 4: combine (BOT) + BG1 (top)
		// Mode 5: BG1 (BOT) + combine (top)
		if (mode_5) begin
			if      ((layer_fg0_en | layer_fg1_en) && bg2c_opq) top_pal_idx_r <= bg2c_pal_idx;
			else if (layer_bg1_en && d16_0_pf2_opq)             top_pal_idx_r <= bg1_pal_idx;
			else                                                 top_pal_idx_r <= PAL_BACKDROP;
		end else begin
			if      (layer_bg1_en && d16_0_pf2_opq)              top_pal_idx_r <= bg1_pal_idx;
			else if ((layer_fg0_en | layer_fg1_en) && bg2c_opq)  top_pal_idx_r <= bg2c_pal_idx;
			else                                                  top_pal_idx_r <= PAL_BACKDROP;
		end
	end else if (pri == 3'd3) begin
		// Mode 3: base layer = BG1 (terrain) above FG1. FG0 = shadow tilemap
		// applied as sub_blend ABOVE the base pixel IF shadow_apply.
		// MAME: bg2_drawed = (bgpri==8) → BG1 drawn + the shadow falls on BG1.
		if (layer_bg1_en && d16_0_pf2_opq) begin
			top_pal_idx_r <= bg1_pal_idx;
			if (mode3_shadow_apply) begin
				blend_en_r    <= 1'b1;
				sub_blend_r   <= (ace_regs[6'h1f][7:0] == 8'h22);
				top_pal_idx_r <= bg2a_pal_idx;   // src = shadow
				bot_pal_idx_r <= bg1_pal_idx;    // dst = BG1
				pixel_alpha_r <= ace_alpha;
			end
		end else if (layer_fg1_en) begin
			top_pal_idx_r <= bg2b_pal_idx;
		end else begin
			top_pal_idx_r <= PAL_BACKDROP;
		end
	end else if (mode_bg2a_top) begin
		// Modes 1/2: bg2b (BOT) | bg1 (mid) | bg2a (top), no blend
		if      (layer_fg0_en && d16_1_pf1_opq) top_pal_idx_r <= bg2a_pal_idx;
		else if (layer_bg1_en && d16_0_pf2_opq) top_pal_idx_r <= bg1_pal_idx;
		else if (layer_fg1_en)                  top_pal_idx_r <= bg2b_pal_idx;
		else                                     top_pal_idx_r <= PAL_BACKDROP;
	end else begin
		// Modes 0/6/7 (default): bg2b (BOT) | bg2a (mid) | bg1 (top)
		if      (layer_bg1_en && d16_0_pf2_opq) top_pal_idx_r <= bg1_pal_idx;
		else if (layer_fg0_en && d16_1_pf1_opq) top_pal_idx_r <= bg2a_pal_idx;
		else if (layer_fg1_en)                  top_pal_idx_r <= bg2b_pal_idx;
		else                                     top_pal_idx_r <= PAL_BACKDROP;
	end
end

// DECO_ACE RGB888 lookup. pal_buf duplicated in 2 M10Ks (top + bot) to allow
// 2 parallel reads without port conflicts. The DMA writes both.
reg [23:0] top_color_raw;   // {B,G,R}
reg [23:0] bot_color_raw;
always @(posedge clk) top_color_raw <= pal_buf_top[top_pal_idx_r[10:0]];
always @(posedge clk) bot_color_raw <= pal_buf_bot[bot_pal_idx_r[10:0]];

// === DECO_ACE FADE (deco_ace.cpp:165-199) — EXACT, bit-identical to MAME.
//   mult (0x1100): c = clamp(0,255, c + ((fadept - c) * fadeps) / 255)
//   add  (0x1000): c = min(c + fadeps, 255)
// Exact /255 = (|prod| * 32897) >> 23 (no mismatch over the whole range). No >>8
// approximation. The player select menu (end of game) writes $3C0040 (ace_regs 0x20-0x26).
// The game clears the fade at init (0x76D6) -> with fadeps=0 the fade changes nothing.
wire [7:0]  fade_pt_r = ace_regs[6'h20][7:0];
wire [7:0]  fade_pt_g = ace_regs[6'h21][7:0];
wire [7:0]  fade_pt_b = ace_regs[6'h22][7:0];
wire [7:0]  fade_st_r = ace_regs[6'h23][7:0];
wire [7:0]  fade_st_g = ace_regs[6'h24][7:0];
wire [7:0]  fade_st_b = ace_regs[6'h25][7:0];
wire [15:0] fade_mode = ace_regs[6'h26];
wire        fade_active = (fade_st_r | fade_st_g | fade_st_b) != 8'd0;
wire        fade_add    = (fade_mode == 16'h1000);   // additive; otherwise multiplicative

// Palette RAW vs FADED (deco_ace.cpp:175-198): the deco_ace palette has 4096 pens:
//   0x000-0x7FF = palette WITH fade (set_pen_color(i)).
//   0x800-0xFFF = the same entries RAW, WITHOUT fade (set_pen_color(i+2048)).
// MAME indexes with paldata[pal_idx]: if pal_idx >= 0x800 -> RAW (no fade). The TEXT (chip0 pf1,
// GFXDECODE base 0x800) ALWAYS uses the raw ones -> the text is NEVER faded. Sprites/BG (base <0x800)
// go raw only with calculated_coloffs (priority bit3 -> +0x800, boogwing.cpp:355).
// In the core: pal_buf is a single copy [0:2047]; the lookup truncates to [10:0] (= correct raw index).
// Index bit 11 (0x800) marks "raw" = fade bypass, PER PIXEL on top and bot separately
// (as in MAME: the 0x800 offset is per source, NOT global). Without this the text (idx >=0x800)
// would be faded -> darkened/blended into the background -> invisible yes/no.
wire top_fade = fade_active & ~(top_pal_idx_r[11] | priority_reg[3]);
wire bot_fade = fade_active & ~(bot_pal_idx_r[11] | priority_reg[3]);

// Alpha factor — MAME deco_ace.cpp get_alpha():
//   alpha = m_ace_ram[val] & 0xff;
//   if (alpha > 0x20) return 0x80;       // special blending command
//   else alpha = 255 - (alpha << 3); clamp 0;
// Boogie Wings uses val=0x1f for the tilemap alpha (chip1.pf1).
wire [7:0] ace_alpha_byte = ace_regs[6'h1f][7:0];
wire [10:0] ace_alpha_sh  = {3'd0, ace_alpha_byte} << 3;   // val << 3
wire [10:0] ace_alpha_sub = 11'd255 - ace_alpha_sh;
wire [7:0]  ace_alpha     = (ace_alpha_byte > 8'h20) ? 8'h80
                          : (ace_alpha_sub[10] ? 8'd0 : ace_alpha_sub[7:0]);

// Blend stage: dst = src*alpha + dst*(255-alpha) (per channel, /256).
// blend_en_r delayed 1 ck to line up with the pal_buf lookup (top/bot_color_raw): from there
// it travels through the colour pipeline together with the data.
reg        blend_en_d;
reg        sub_blend_d;
reg [7:0]  alpha_d;
always @(posedge clk) blend_en_d  <= blend_en_r;
always @(posedge clk) sub_blend_d <= sub_blend_r;
always @(posedge clk) alpha_d     <= pixel_alpha_r;

// ============================================================================
// PIPELINED COLOUR CHAIN: DECO_ACE fade + blend, 5 registers clocked EVERY cycle.
// Done combinationally from the palette BRAM to the output, fade and blend take 29 ns
// (2 fade multipliers + 1 blend multiplier), far beyond the 10.4 ns cycle of the core clock.
// The output is EXACTLY the combinational result delayed by 5 clk: every signal
// travelling with it (raw/fade flags, add mode, blend_en/sub/alpha, fade parameters)
// is taken at the SAME instant as the colour (stage A) and travels with it.
// Latency from hcnt to the output: lb read, lb_rd, *_pal_idx_r, *_color_raw = 4, + 5 = 9 clk.
// A pixel lasts 14 clk and the video output samples in the ce_pix cycle (the 14th): 9 < 14 ->
// the same pixel is sampled as with the combinational chain (no layer shift: all layers
// go through the same pipeline).
//
// MAME formulas unchanged, bit for bit:
//  fade mult (0x1100): c = clamp(0,255, c + ((fadept - c) * fadeps) / 255)
//    exact /255 = (|prod| * 32897) >> 23, quotient truncated toward zero
//  fade add  (0x1000): c = min(c + fadeps, 255)
//  alpha_blend_r32: (src * alpha + dst * (256 - alpha)) >> 8
//  sub_blend_r32 (boogwing.cpp:180-188): (inv_src * alpha + dst * (256 - alpha)) >> 9,
//    inv_src = 0xff - src; never below zero (a plain subtraction would clamp to BLACK).
//  Mapping: dst = bot_color (BG1), src = top_color (FG0 shadow) - MAME line 408.
// Stages: A = (pt-c)*st and saturated sum of the add mode | B = |prod|/255 |
//         C = faded colour | D = blend products | E = sum, select, output.
// ============================================================================
wire [23:0] fade_pt24 = {fade_pt_b, fade_pt_g, fade_pt_r};   // same {B,G,R} order
wire [23:0] fade_st24 = {fade_st_b, fade_st_g, fade_st_r};

function signed [16:0] fade_prod(input [7:0] c, input [7:0] pt, input [7:0] st);
	fade_prod = ($signed({1'b0, pt}) - $signed({1'b0, c})) * $signed({1'b0, st});
endfunction

function [7:0] fade_add8(input [7:0] c, input [7:0] st);
	reg [9:0] asum;
	begin
		asum      = {2'd0, c} + {2'd0, st};
		fade_add8 = asum[9:8] != 2'd0 ? 8'hFF : asum[7:0];
	end
endfunction

function [8:0] fade_qmag(input [16:0] prod);   // exact |prod| / 255
	reg [15:0] mag;
	reg [31:0] qmul;
	begin
		mag       = prod[16] ? (~prod[15:0] + 16'd1) : prod[15:0];
		qmul      = mag * 32'd32897;
		fade_qmag = qmul[31:23];
	end
endfunction

function [7:0] fade_fin(input [7:0] c, input neg, input [8:0] qmag);
	reg signed [9:0] q, res;
	begin
		q        = neg ? -$signed({1'b0, qmag}) : $signed({1'b0, qmag});
		res      = $signed({2'b0, c}) + q;
		fade_fin = res[9] ? 8'd0 : (res > 10'sd255 ? 8'hFF : res[7:0]);
	end
endfunction

// Stage A
reg [23:0] ta_c, ba_c, ta_add, ba_add;
reg [50:0] ta_prod, ba_prod;                 // 3 x 17
reg        ta_fade, ba_fade, a_add, a_blend, a_sub;
reg [7:0]  a_alpha;
// Stage B
reg [23:0] tb_c, bb_c, tb_add, bb_add;
reg [26:0] tb_q, bb_q;                       // 3 x 9
reg [2:0]  tb_neg, bb_neg;
reg        tb_fade, bb_fade, b_add, b_blend, b_sub;
reg [7:0]  b_alpha;
// Stage C
reg [23:0] tc_col, bc_col;
reg        c_blend, c_sub;
reg [7:0]  c_alpha;
// Stage D
reg [50:0] d_s, d_d;                         // 3 x 17
reg [23:0] d_top;
reg        d_blend, d_sub;
// Stage E
reg [23:0] rgb_q;                            // {R,G,B}

integer ch;
always @(posedge clk) begin
	// A
	ta_c    <= top_color_raw;  ba_c    <= bot_color_raw;
	ta_fade <= top_fade;       ba_fade <= bot_fade;      a_add <= fade_add;
	a_blend <= blend_en_d;     a_sub   <= sub_blend_d;   a_alpha <= alpha_d;
	for (ch = 0; ch < 3; ch = ch + 1) begin
		ta_prod[ch*17 +: 17] <= fade_prod(top_color_raw[ch*8 +: 8], fade_pt24[ch*8 +: 8], fade_st24[ch*8 +: 8]);
		ba_prod[ch*17 +: 17] <= fade_prod(bot_color_raw[ch*8 +: 8], fade_pt24[ch*8 +: 8], fade_st24[ch*8 +: 8]);
		ta_add[ch*8 +: 8]    <= fade_add8(top_color_raw[ch*8 +: 8], fade_st24[ch*8 +: 8]);
		ba_add[ch*8 +: 8]    <= fade_add8(bot_color_raw[ch*8 +: 8], fade_st24[ch*8 +: 8]);
	end
	// B
	tb_c    <= ta_c;     bb_c    <= ba_c;
	tb_add  <= ta_add;   bb_add  <= ba_add;
	tb_fade <= ta_fade;  bb_fade <= ba_fade;  b_add <= a_add;
	b_blend <= a_blend;  b_sub   <= a_sub;    b_alpha <= a_alpha;
	for (ch = 0; ch < 3; ch = ch + 1) begin
		tb_q[ch*9 +: 9] <= fade_qmag(ta_prod[ch*17 +: 17]);
		bb_q[ch*9 +: 9] <= fade_qmag(ba_prod[ch*17 +: 17]);
		tb_neg[ch]      <= ta_prod[ch*17 + 16];
		bb_neg[ch]      <= ba_prod[ch*17 + 16];
	end
	// C
	c_blend <= b_blend;  c_sub <= b_sub;  c_alpha <= b_alpha;
	for (ch = 0; ch < 3; ch = ch + 1) begin
		tc_col[ch*8 +: 8] <= !tb_fade ? tb_c[ch*8 +: 8]
		                   : b_add    ? tb_add[ch*8 +: 8]
		                   :            fade_fin(tb_c[ch*8 +: 8], tb_neg[ch], tb_q[ch*9 +: 9]);
		bc_col[ch*8 +: 8] <= !bb_fade ? bb_c[ch*8 +: 8]
		                   : b_add    ? bb_add[ch*8 +: 8]
		                   :            fade_fin(bb_c[ch*8 +: 8], bb_neg[ch], bb_q[ch*9 +: 9]);
	end
	// D
	d_top <= tc_col;  d_blend <= c_blend;  d_sub <= c_sub;
	for (ch = 0; ch < 3; ch = ch + 1) begin
		d_s[ch*17 +: 17] <= (c_sub ? 8'hff - tc_col[ch*8 +: 8] : tc_col[ch*8 +: 8]) * c_alpha;
		d_d[ch*17 +: 17] <= bc_col[ch*8 +: 8] * (9'd256 - {1'b0, c_alpha});
	end
end

// E: sum of the products, >>8 (alpha) or >>9 (sub), or top directly when there is no blend.
wire [16:0] e_sum_r = d_s[16:0]  + d_d[16:0];
wire [16:0] e_sum_g = d_s[33:17] + d_d[33:17];
wire [16:0] e_sum_b = d_s[50:34] + d_d[50:34];
always @(posedge clk)
	rgb_q <= !d_blend ? {d_top[7:0], d_top[15:8], d_top[23:16]}
	       :  d_sub   ? {e_sum_r[16:9], e_sum_g[16:9], e_sum_b[16:9]}
	       :            {e_sum_r[15:8], e_sum_g[15:8], e_sum_b[15:8]};

// rgb_out: {R, G, B} (video_r = rgb[23:16]), registered output of the colour pipeline.
assign rgb_out = rgb_q;

// =====================================================================
// AUDIO subsystem (boogwings_audio.sv)
// =====================================================================
// Audio CPU ROM download: ioctl_dout is 16-bit (word), the ROM is byte-addressed.
// ioctl_addr steps by 2 (= byte units), low byte = [7:0], high byte = [15:8].
// Each ioctl_wr writes 2 sequential bytes: byte 0 at addr N, byte 1 at addr N+1,
// through two write ports (we_lo / we_hi) of the audio ROM BRAM in boogwings_audio.
reg        audio_rom_we_lo, audio_rom_we_hi;
wire       pocket_arom_busy;   // POCKET: audio ROM write busy flag (always 0, see ioctl_wait at the end)
reg [15:0] audio_rom_waddr_lo, audio_rom_waddr_hi;
reg [7:0]  audio_rom_wdata_lo, audio_rom_wdata_hi;
reg        ioctl_wr_prev_aud;
always @(posedge clk) begin
	audio_rom_we_lo <= 1'b0;
	audio_rom_we_hi <= 1'b0;
	ioctl_wr_prev_aud <= ioctl_wr;
	if (ioctl_wr && !ioctl_wr_prev_aud && is_audio_dl) begin
		audio_rom_we_lo    <= 1'b1;
		audio_rom_waddr_lo <= ioctl_addr[15:0] - AUDIO_DL_LO[15:0];
		audio_rom_wdata_lo <= ioctl_dout[7:0];
		audio_rom_we_hi    <= 1'b1;
		audio_rom_waddr_hi <= (ioctl_addr[15:0] - AUDIO_DL_LO[15:0]) + 16'd1;
		audio_rom_wdata_hi <= ioctl_dout[15:8];
	end
end

wire [27:0] oki0_ddr_addr_w, oki1_ddr_addr_w;
wire        oki0_ddr_req_w, oki1_ddr_req_w;
wire [31:0] oki0_ddr_data_w, oki1_ddr_data_w;     // 32-bit port (port 5/6 with prefetch)
wire        oki0_ddr_ack_w, oki1_ddr_ack_w;

// Audio cen: frame-aligned gating INSIDE the Template.sv counters (the counters freeze
// while paused_safe, the pulse is NOT cut by an external AND). Clean restart at the frame
// boundary, like F2 .cen_in(~obj_paused). The ce_* arrive already stopped during pause/SS.

boogwings_audio #(.SS_HUC_RAM_IDX(SS_IDX_HUC_RAM), .SS_HUC_CPU_IDX(SS_IDX_HUC_CPU),
                  .SS_OKI0_IDX(SS_IDX_OKI0), .SS_OKI1_IDX(SS_IDX_OKI1),
                  .SS_YM_IDX(SS_IDX_YM), .SS_AUDIO_BUS_IDX(SS_IDX_AUDIO_BUS)) u_audio (
	.clk            (clk),
	.reset          (reset),
	.ce_audio       (ce_audio),
	.ce_ym          (ce_ym),
	.ce_ym_p1       (ce_ym_p1),
	.ce_oki0        (ce_oki0),
	.ce_oki1        (ce_oki1),
	.ce_audio_cnt_in  (ce_audio_cnt_in),
	.ce_ym_cnt_in     (ce_ym_cnt_in),
	.ce_ym_toggle_in  (ce_ym_toggle_in),
	.ce_oki0_cnt_in   (ce_oki0_cnt_in),
	.ce_oki1_cnt_in   (ce_oki1_cnt_in),
	.ce_audio_cnt_load (ce_audio_cnt_load),
	.ce_ym_cnt_load    (ce_ym_cnt_load),
	.ce_ym_toggle_load (ce_ym_toggle_load),
	.ce_oki0_cnt_load  (ce_oki0_cnt_load),
	.ce_oki1_cnt_load  (ce_oki1_cnt_load),
	.ce_cnt_load_wr    (ce_cnt_load_wr),
	.pause          (paused_safe),
	.soundlatch_data     (sndlatch_data),
	.soundlatch_irq_pulse(sndlatch_irq_main_pulse),
	.rom_we_lo      (audio_rom_we_lo),
	.rom_we_hi      (audio_rom_we_hi),
	.rom_waddr_lo   (audio_rom_waddr_lo),
	.rom_waddr_hi   (audio_rom_waddr_hi),
	.rom_wdata_lo   (audio_rom_wdata_lo),
	.rom_wdata_hi   (audio_rom_wdata_hi),
	.oki0_ddr_addr  (oki0_ddr_addr_w),
	.oki0_ddr_req   (oki0_ddr_req_w),
	.oki0_ddr_data  (oki0_ddr_data_w),
	.oki0_ddr_ack   (oki0_ddr_ack_w),
	.oki1_ddr_addr  (oki1_ddr_addr_w),
	.oki1_ddr_req   (oki1_ddr_req_w),
	.oki1_ddr_data  (oki1_ddr_data_w),
	.oki1_ddr_ack   (oki1_ddr_ack_w),
	.osd_sel_fm     (osd_sel_fm),
	.osd_sel_oki0   (osd_sel_oki0),
	.osd_sel_oki1   (osd_sel_oki1),
	.osd_presence   (osd_presence),
	.audio_l        (audio_l),
	.audio_r        (audio_r),
	.ss_huc_ram     (ssb[SS_IDX_HUC_RAM]),
	.ss_huc_cpu     (ssb[SS_IDX_HUC_CPU]),
	.ss_oki0        (ssb[SS_IDX_OKI0]),
	.ss_oki1        (ssb[SS_IDX_OKI1]),
	.ss_ym          (ssb[SS_IDX_YM]),
	.ss_audio_bus   (ssb[SS_IDX_AUDIO_BUS])
);

// =====================================================================
// TILEMAP ROM routing (4 clients = 2 chips × 2 layers), no arbiter:
//   deco16_0 pf1 (text) → txt_rom_*         (SDRAM ba3, see below)
//   deco16_0 pf2 (BG1)  → tilerom_bg1_*     (SDRAM ba3, see below)
//   deco16_1 pf1 (FG0)  → tilerom_fg0_*     (SDRAM ba0)
//   deco16_1 pf2 (FG1)  → tilerom_fg1_*     (SDRAM ba1)
//
// Region IDs come from the deco16ic instances via d16_*_pf*_rid (parameter-driven).
// =====================================================================
// chip1.pf1 → tilerom_fg0_* (ba0), chip1.pf2 → tilerom_fg1_* (ba1).
// No round-robin: 2 independent SDRAM ports = real parallelism.
assign tilerom_fg0_addr      = d16_1_pf1_rom_addr;
assign tilerom_fg0_region_id = d16_1_pf1_rid;
assign tilerom_fg0_req       = d16_1_pf1_rom_req;
wire [31:0] bg2a_arb_data  = tilerom_fg0_data;
wire        bg2a_arb_valid = tilerom_fg0_valid;

assign tilerom_fg1_addr      = d16_1_pf2_rom_addr;
assign tilerom_fg1_region_id = d16_1_pf2_rid;
assign tilerom_fg1_req       = d16_1_pf2_rom_req;
wire [31:0] bg2b_arb_data  = tilerom_fg1_data;
wire        bg2b_arb_valid = tilerom_fg1_valid;


// =====================================================================
// DDRAM multi-port instance (ddram_4port, u_ddram below)
//   Port wr  : sprite ROM + OKI samples ioctl download
//   Port rd4 : sprite ROM chip0, 32-bit (inline bridge)
//   Port rd5 : OKI #0 samples
//   Port rd6 : OKI #1 samples
//   Port rd9 : sprite ROM chip1, 32-bit (inline bridge)
// =====================================================================
// Sprite chip0 (sprites1) — inline bridge, NO cache (saves LABs).
wire [23:0] sprite_romaddr;
wire        sprite_romreq;
reg  [31:0] sprite_romdata;
reg         sprite_romvalid;
reg  [27:0] sprite_ddr_rdaddr;
reg         sprite_ddr_rd_req;
wire [31:0] sprite_ddr_dout;
wire        sprite_ddr_rd_ack;
localparam [27:0] SPRITES1_BASE = 28'h0400000;

reg [1:0] spr1_state;
localparam SPR1_IDLE = 2'd0, SPR1_WAIT = 2'd1;
reg spr1_req_prev;
always @(posedge clk) begin
	if (reset) begin
		spr1_state        <= SPR1_IDLE;
		spr1_req_prev     <= 0;
		sprite_ddr_rd_req <= 0;
		sprite_romvalid   <= 0;
	end else begin
		spr1_req_prev   <= sprite_romreq;
		sprite_romvalid <= 0;
		case (spr1_state)
			SPR1_IDLE: if (sprite_romreq & ~spr1_req_prev) begin
				// Download interleave 2x: 1 source byte -> 2 DDR3 bytes.
				// sprite_romaddr is in MAME space (= 4MB source).
				// DDR3 = 8MB interleaved -> shift left 1.
				sprite_ddr_rdaddr <= SPRITES1_BASE + {3'd0, sprite_romaddr, 1'b0};
				sprite_ddr_rd_req <= ~sprite_ddr_rd_req;
				spr1_state <= SPR1_WAIT;
			end
			SPR1_WAIT: if (sprite_ddr_rd_ack == sprite_ddr_rd_req) begin
				sprite_romdata  <= sprite_ddr_dout;
				sprite_romvalid <= 1'b1;
				spr1_state <= SPR1_IDLE;
			end
			default: spr1_state <= SPR1_IDLE;
		endcase
	end
end

// Sprite chip1 (sprites2) — inline bridge, NO cache (saves LABs).
// req_pulse → toggle DDR3 → wait ack → resp_valid pulse.
wire [23:0] sprite2_romaddr;
wire        sprite2_romreq;
reg  [31:0] sprite2_romdata;
reg         sprite2_romvalid;
reg  [27:0] sprite2_ddr_rdaddr;
reg         sprite2_ddr_rd_req;
wire [31:0] sprite2_ddr_dout;
wire        sprite2_ddr_rd_ack;
// chip0 occupies 0x400000..0x7FFFFF, so
// chip1 = chip0_base + chip0_size = 0x0400000 + 0x0400000 = 0x0800000.
localparam [27:0] SPRITES2_BASE = 28'h0800000;

reg [1:0] spr2_state;
localparam SPR2_IDLE = 2'd0, SPR2_REQ = 2'd1, SPR2_WAIT = 2'd2, SPR2_DONE = 2'd3;
reg spr2_req_prev;
always @(posedge clk) begin
	if (reset) begin
		spr2_state       <= SPR2_IDLE;
		spr2_req_prev    <= 0;
		sprite2_ddr_rd_req <= 0;
		sprite2_romvalid <= 0;
	end else begin
		spr2_req_prev    <= sprite2_romreq;
		sprite2_romvalid <= 0;
		case (spr2_state)
			SPR2_IDLE: if (sprite2_romreq & ~spr2_req_prev) begin
				// Download interleave 2x: shift left 1 (see SPR1).
				sprite2_ddr_rdaddr <= SPRITES2_BASE + {3'd0, sprite2_romaddr, 1'b0};
				sprite2_ddr_rd_req <= ~sprite2_ddr_rd_req;
				spr2_state <= SPR2_WAIT;
			end
			SPR2_WAIT: if (sprite2_ddr_rd_ack == sprite2_ddr_rd_req) begin
				sprite2_romdata  <= sprite2_ddr_dout;
				sprite2_romvalid <= 1'b1;
				spr2_state <= SPR2_IDLE;
			end
			default: spr2_state <= SPR2_IDLE;
		endcase
	end
end

// ROM download layout (ioctl_addr, index 0) and destinations:
//   0x110000-0x12FFFF  tiles1 (128 KB, text)                → SDRAM ba3 (sdram_bridge)
//   0x130000-0x42FFFF  tiles2 (3 MB, BG1 5bpp = mbd-01 + mbd-00 + mbd-02) → SDRAM ba3 (sdram_bridge)
//   0x430000-0x62FFFF  tiles3 #1 (2 MB: mbd-03 plane 0+1 = LO, mbd-04 plane 2+3 = HI) → SDRAM ba0
//   0x630000-0x82FFFF  tiles3 #2 (duplicate for SDRAM ba1 FG1, NOT sprites)
//   0x830000-0x102FFFF sprites (8 MB)                       → DDR3, chip0+chip1 (here)
// Only the sprites and the OKI samples are written to DDR3 by this module.
localparam [26:0] SPRITE_DL_LO = 27'h830000;
localparam [26:0] SPRITE_DL_SZ = 27'h800000;
// Tile3 (BG2):
//   0x430000-0x52FFFF = mbd-03 (1 MB, plane 0+1 = LO)
//   0x530000-0x62FFFF = mbd-04 (1 MB, plane 2+3 = HI)
// Tile1 (text):
//   0x110000-0x11FFFF = tiles1_lo (64 KB)
//   0x120000-0x12FFFF = tiles1_hi (64 KB)
// Audio CPU ROM (H6280): 64 KB BRAM inside the audio module
localparam [26:0] AUDIO_DL_LO  = 27'h100000;
localparam [26:0] AUDIO_DL_SZ  = 27'h010000;
wire is_audio_dl  = ioctl_download && (ioctl_index == 16'd0)
                     && (ioctl_addr >= AUDIO_DL_LO)
                     && (ioctl_addr <  AUDIO_DL_LO + AUDIO_DL_SZ);
wire is_sprite_dl = ioctl_download && (ioctl_index == 16'd0)
                     && (ioctl_addr >= SPRITE_DL_LO)
                     && (ioctl_addr <  SPRITE_DL_LO + SPRITE_DL_SZ);
// OKI1/OKI2 (512 KB each) → DDR3 base 0x5500000 / 0x5580000
localparam [26:0] OKI1_DL_LO  = 27'h1030000;
localparam [26:0] OKI1_DL_SZ  = 27'h0080000;
localparam [26:0] OKI2_DL_LO  = 27'h10B0000;
localparam [26:0] OKI2_DL_SZ  = 27'h0080000;
localparam [27:0] DDR_OKI1_BASE = 28'h5500000;
localparam [27:0] DDR_OKI2_BASE = 28'h5580000;
wire is_oki1_dl  = ioctl_download && (ioctl_index == 16'd0)
                    && (ioctl_addr >= OKI1_DL_LO)
                    && (ioctl_addr <  OKI1_DL_LO + OKI1_DL_SZ);
wire is_oki2_dl  = ioctl_download && (ioctl_index == 16'd0)
                    && (ioctl_addr >= OKI2_DL_LO)
                    && (ioctl_addr <  OKI2_DL_LO + OKI2_DL_SZ);
reg  [27:0] ddr_dl_waddr;
reg  [15:0] ddr_dl_wdata;
reg         ddr_dl_we_req;
wire        ddr_dl_we_ack;
reg         ioctl_wr_prev_ddr;
// Sprite download interleave: the MAME tile_16x16_layout takes
// planes 0,1 from the LO region and planes 2,3 from the HI region. The sprite bridge reads 4
// consecutive bytes. The download interleaves them so DDR3 holds 4 bytes = [LO+0, LO+1, HI+0, HI+1].
//
// Source layout (ioctl_addr - SPRITE_DL_LO):
//   0..2MB = chip0 LO (mbd-06)
//   2..4MB = chip0 HI (mbd-05)
//   4..6MB = chip1 LO (mbd-08)
//   6..8MB = chip1 HI (mbd-07)
// Destination layout in DDR3 (starting at SPRITES1_BASE):
//   chip0 occupies 0..4MB (4 bytes for every 2 source bytes)
//   chip1 occupies 4..8MB
// For each source word16 (2 bytes) at offset rel:
//   if rel < 2MB: chip=0, region=LO, dst_base=0          , dst_off=2*rel
//   if rel < 4MB: chip=0, region=HI, dst_base=2          , dst_off=2*(rel-2MB)
//   if rel < 6MB: chip=1, region=LO, dst_base=0+4MB      , dst_off=2*(rel-4MB)
//   if rel < 8MB: chip=1, region=HI, dst_base=2+4MB      , dst_off=2*(rel-6MB)
// (the order of the 4-byte groups is then rearranged as described below)
wire [22:0] spr_src_off = ioctl_addr[22:0] - SPRITE_DL_LO[22:0];   // 0..8MB
wire [1:0]  spr_chip_reg = spr_src_off[22:21];                      // 00=c0LO 01=c0HI 10=c1LO 11=c1HI
wire [20:0] spr_off_in_region = spr_src_off[20:0];                  // 0..2MB byte addr
// HALF-ADJACENT layout (as in Night Slashers): the source word w =
// off_in_region[20:1] = {code, half, row[3:0]} is written to the DDR group
// {code, row, half} (bit 4 at the bottom), which is the address bw_sprites requests
// ({code, row_use, half_use}): the two halves A/B of a row are adjacent in
// DDR and the fetch of B finds the row already open. Same number of bytes,
// only the order of the groups inside the 32-group block changes.
wire [19:0] spr_w   = spr_off_in_region[20:1];
wire [19:0] spr_w_s = {spr_w[19:5], spr_w[3:0], spr_w[4]};
wire [22:0] spr_dst_off = (spr_chip_reg[1] ? 23'h400000 : 23'h000000)  // chip base
                        + ({1'b0, spr_w_s, 2'b00})                     // 4*group (half-adjacent)
                        + (spr_chip_reg[0] ? 23'd2 : 23'd0);           // LO vs HI offset

// Direct DDR3 write per download word (no pending queue: a queue
// races with the slow ddr_dl_we_ack).
always @(posedge clk) begin
	ioctl_wr_prev_ddr <= ioctl_wr;
	if (ioctl_wr && !ioctl_wr_prev_ddr) begin
		if (is_sprite_dl) begin
			ddr_dl_waddr  <= 28'h0400000 + {5'd0, spr_dst_off};
			ddr_dl_wdata  <= ioctl_dout;
			ddr_dl_we_req <= ~ddr_dl_we_req;
		end else if (is_oki1_dl) begin
			ddr_dl_waddr  <= DDR_OKI1_BASE + {1'b0, ioctl_addr - OKI1_DL_LO};
			ddr_dl_wdata  <= ioctl_dout;
			ddr_dl_we_req <= ~ddr_dl_we_req;
		end else if (is_oki2_dl) begin
			ddr_dl_waddr  <= DDR_OKI2_BASE + {1'b0, ioctl_addr - OKI2_DL_LO};
			ddr_dl_wdata  <= ioctl_dout;
			ddr_dl_we_req <= ~ddr_dl_we_req;
		end
	end
end

// =====================================================================
// tile_perm: 4 independent toggles for hardware debug (run time).
// =====================================================================
function [7:0] brev8(input [7:0] b);
	brev8 = {b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]};
endfunction

function [31:0] tile_perm(input [15:0] hi_w, input [15:0] lo_w,
                          input swap_hl, input brev_en, input nibsw_en, input bs_ab_en);
	reg [31:0] w0, w1, w2, w3;
	begin
		w0 = swap_hl ? {lo_w, hi_w} : {hi_w, lo_w};
		w1 = bs_ab_en ?
			{w0[23:16], w0[31:24], w0[7:0],  w0[15:8]} :
			w0;
		w2 = nibsw_en ?
			{w1[27:24], w1[31:28], w1[19:16], w1[23:20],
			 w1[11:8],  w1[15:12], w1[3:0],   w1[7:4]} :
			w1;
		w3 = brev_en ?
			{brev8(w2[31:24]), brev8(w2[23:16]), brev8(w2[15:8]), brev8(w2[7:0])} :
			w2;
		tile_perm = w3;
	end
endfunction

// =====================================================================
// BG1 chip0.pf2 5bpp → SDRAM ba3 (jtframe_sdram64).
// The SDRAM bridge (in sdram_bridge.sv) handles 3 regions: mbd-01/mbd-00/mbd-02.
// - 4 base planes: 2 sequential fetches (MID+LO) → tilerom_bg1_data 32-bit
// - p4 (mbd-02): dedicated channel → tilerom_bg1_p4_data 8-bit RAW (no tile_perm)
// =====================================================================
assign tilerom_bg1_addr   = d16_0_pf2_rom_addr;
assign tilerom_bg1_req    = d16_0_pf2_rom_req;
assign tilerom_bg1_p4_req = d16_0_pf2_p4_req;

// Plain read: the data in SDRAM ba3 is already decrypted by the FPGA during the
// download (deco56_ioctl_decrypt_reg.sv).
assign d16_0_pf2_rom_data  = tile_perm(tilerom_bg1_data[31:16], tilerom_bg1_data[15:0],
                                         osd_bg1_swap_hl, osd_bg1_brev8,
                                         osd_bg1_nibsw,   osd_bg1_bs_ab);
assign d16_0_pf2_rom_valid = tilerom_bg1_valid;
assign d16_0_pf2_p4_data   = tilerom_bg1_p4_data;
assign d16_0_pf2_p4_valid  = tilerom_bg1_p4_valid;

// =====================================================================
// BG2 chip1.pf1 / chip1.pf2 (4bpp, no p4 plane): the tile data used by
// chip1 comes from SDRAM (tilerom_fg0_* / tilerom_fg1_*).
// =====================================================================
// 32-bit data from SDRAM (tilerom_fg0_*). The SDRAM word needs HI/LO swapped
// compared with the DDR3 layout (verified on hardware).
assign d16_1_pf1_rom_data  = tile_perm(bg2a_arb_data[15:0], bg2a_arb_data[31:16],
                                         osd_fg0_swap_hl, osd_fg0_brev8,
                                         osd_fg0_nibsw,   osd_fg0_bs_ab);
assign d16_1_pf1_rom_valid = bg2a_arb_valid;

assign d16_1_pf2_rom_data  = tile_perm(bg2b_arb_data[15:0], bg2b_arb_data[31:16],
                                         osd_fg1_swap_hl, osd_fg1_brev8,
                                         osd_fg1_nibsw,   osd_fg1_bs_ab);
assign d16_1_pf2_rom_valid = bg2b_arb_valid;

// =====================================================================
// Text chip0.pf1 → SDRAM (tile1, 128 KB = LO region 64 KB + HI region 64 KB).
// Download: ioctl_addr 0x110000-0x11FFFF (LO) / 0x120000-0x12FFFF (HI).
// =====================================================================
// POCKET: tile1 lives in SDRAM (bank ba3, after BG1) and is read through the
// text client of sdram_bridge (request toggle, valid pulse, data {hi, lo});
// the bridge also writes it during the download (prog_*).
wire [15:0] txt_hi_word = txt_rom_data[31:16];
wire [15:0] txt_lo_word = txt_rom_data[15:0];
wire        txt_valid_r = txt_rom_valid;
assign txt_rom_addr = d16_0_pf1_rom_addr;
assign txt_rom_req  = d16_0_pf1_rom_req;

assign d16_0_pf1_rom_data  = tile_perm(txt_hi_word, txt_lo_word,
                                         osd_bg0_swap_hl, osd_bg0_brev8,
                                         osd_bg0_nibsw,   osd_bg0_bs_ab);
assign d16_0_pf1_rom_valid = txt_valid_r;

// === Savestate DDR MUX (gated on ss_ddr_grant, with latch-on-drain QUIESCENCE) ===
// The MUX does NOT switch on raw ss_busy: that would happen while ddram_4port has sprite/OKI
// fetches in flight -> the savestate DDRAM_DOUT_READY pulses would be eaten by the arbiter FSM ->
// corrupted or hung OKI/sprites. ss_ddr_grant RISES only after the DDR bus is physically
// DRAINED (no transaction in flight, stable for N cycles) and then STAYS latched until the end
// of the SS. It does NOT depend on rd_ack==rd_req: under hold the arbiter does not serve the
// sprite/OKI rd_req, so waiting for that quiescence would hang a restore at COLD BOOT (initial
// cache miss not served). Equivalent to the F2 ddr_mux / RESTORE_WAIT_PAUSE. See the hold/grant block below.
wire  [7:0] d4_DDRAM_BURSTCNT;
wire [28:0] d4_DDRAM_ADDR;
wire        d4_DDRAM_RD;
wire [63:0] d4_DDRAM_DIN;
wire  [7:0] d4_DDRAM_BE;
wire        d4_DDRAM_WE;

ddr_if ss_ddr();   // declared here (before the MUX that uses ss_ddr.read/write)
// ss_hold: as soon as the SS asks for the bus (ss_busy), it BLOCKS ddram_4port from issuing (it stays in
// state 0, requests pending). So the arbiter issues no reads while the SS has/takes the bus.
// ss_ddr_grant: the MUX routes DDRAM_* to the SS only after the arbiter has gone idle (ss_idle).
// At the end (ss_busy low & no SS transaction in flight) everything is released: ss_hold falls,
// the arbiter resumes serving the queued requests. NO read is lost.
// The savestate DDR gate is a generic cross-core module (rtl/common/ss_ddr_gate.sv).
// The TRANSPARENCY RULE (hold/grant fall only on internal SS signals, drain-on-rise)
// lives in the module: the core inherits it by instantiating it. See ss_ddr_gate.sv.
wire ss_hold, ss_ddr_grant;
wire ss_tx_inflight = ss_ddr.read | ss_ddr.write;   // transaction of the savestate ONLY in flight
ss_ddr_gate #(.AW(29), .DRAIN_TH(3)) u_ss_ddr_gate (
	.clk            (clk),
	.reset          (reset),
	.ss_busy        (ss_busy),
	.ss_tx_inflight (ss_tx_inflight),
	// game master (arbiter)
	.game_burstcnt  (d4_DDRAM_BURSTCNT),
	.game_addr      (d4_DDRAM_ADDR),
	.game_rd        (d4_DDRAM_RD),
	.game_din       (d4_DDRAM_DIN),
	.game_be        (d4_DDRAM_BE),
	.game_we        (d4_DDRAM_WE),
	// savestate master (memory_stream)
	.ss_burstcnt    (ss_DDRAM_BURSTCNT),
	.ss_addr        (ss_DDRAM_ADDR),
	.ss_rd          (ss_DDRAM_RD),
	.ss_din         (ss_DDRAM_DIN),
	.ss_be          (ss_DDRAM_BE),
	.ss_we          (ss_DDRAM_WE),
	.DDRAM_BUSY     (DDRAM_BUSY),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	// muxed outputs to the DDR3 controller
	.DDRAM_BURSTCNT (DDRAM_BURSTCNT),
	.DDRAM_ADDR     (DDRAM_ADDR),
	.DDRAM_RD       (DDRAM_RD),
	.DDRAM_DIN      (DDRAM_DIN),
	.DDRAM_BE       (DDRAM_BE),
	.DDRAM_WE       (DDRAM_WE),
	.ss_hold        (ss_hold),
	.ss_ddr_grant   (ss_ddr_grant)
);

ddram_4port u_ddram (
	.DDRAM_CLK       (DDRAM_CLK),
	.DDRAM_BUSY      (DDRAM_BUSY),
	.DDRAM_BURSTCNT  (d4_DDRAM_BURSTCNT),
	.DDRAM_ADDR      (d4_DDRAM_ADDR),
	.DDRAM_DOUT      (DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD        (d4_DDRAM_RD),
	.DDRAM_DIN       (d4_DDRAM_DIN),
	.DDRAM_BE        (d4_DDRAM_BE),
	.DDRAM_WE        (d4_DDRAM_WE),

	// Write port: sprite + OKI download (muxed above in ddr_dl_*)
	.wraddr (ddr_dl_waddr),
	.din    (ddr_dl_wdata),
	.we_byte(1'b0),
	.we_req (ddr_dl_we_req),
	.we_ack (ddr_dl_we_ack),

	// Read port 1: UNUSED (H6280 ROM in BRAM rom_even/rom_odd)
	.rdaddr (28'd0), .dout (), .rd_req(1'b0), .rd_ack(),
	// Read port 2: UNUSED (OKI #0 on port 5, 32-bit with prefetch)
	.rdaddr2(28'd0), .dout2(), .rd_req2(1'b0), .rd_ack2(),
	// Read port 3: UNUSED (OKI #1 on port 6, 32-bit with prefetch)
	.rdaddr3(28'd0), .dout3(), .rd_req3(1'b0), .rd_ack3(),

	// Read port 4: sprite ROM chip0, 32-bit
	.rdaddr4(sprite_ddr_rdaddr),
	.dout4  (sprite_ddr_dout),
	.rd_req4(sprite_ddr_rd_req),
	.rd_ack4(sprite_ddr_rd_ack),

	// Read port 5: OKI #0 samples (512 KB @ DDR3 0x5500000, 32-bit + prefetch)
	.rdaddr5(oki0_ddr_addr_w), .dout5(oki0_ddr_data_w),
	.rd_req5(oki0_ddr_req_w),  .rd_ack5(oki0_ddr_ack_w),

	// Read port 6: OKI #1 samples (512 KB @ DDR3 0x5580000, 32-bit + prefetch)
	.rdaddr6(oki1_ddr_addr_w), .dout6(oki1_ddr_data_w),
	.rd_req6(oki1_ddr_req_w),  .rd_ack6(oki1_ddr_ack_w),

	// Read port 7: UNUSED (BG2 chip1.pf2 is read from SDRAM)
	.rdaddr7(28'd0), .dout7(), .rd_req7(1'b0), .rd_ack7(),

	// Read port 8: UNUSED (text is read from SDRAM)
	.rdaddr8(28'd0), .dout8(), .rd_req8(1'b0), .rd_ack8(),

	// Read port 9: sprites2 chip1 ROM (DDR3 from SPRITES2_BASE, 4 MB)
	.rdaddr9(sprite2_ddr_rdaddr),
	.dout9  (sprite2_ddr_dout),
	.rd_req9(sprite2_ddr_rd_req),
	.rd_ack9(sprite2_ddr_rd_ack),

	// Copy port unused
	.cpaddr(28'd0), .cpdout(), .cpwr(), .cpreq(1'b0), .cpbusy(),
	.ss_idle(ddram_ss_idle),
	.ss_hold(ss_hold)
);
wire ddram_ss_idle;

// =====================================================================
// SAVESTATE — infrastructure (DORMANT until ss_save/ss_load arrive).
// memory_stream (inside save_state_data) speaks ddr_if; it is adapted to the raw
// ss_DDRAM_* signals that the MUX above routes to DDRAM_* when granted.
// With no ss_save/ss_load → ss_busy=0 → the MUX always gives the DDR to the game.
// =====================================================================
wire        ss_busy;
wire  [7:0] ss_DDRAM_BURSTCNT;
wire [28:0] ss_DDRAM_ADDR;
wire        ss_DDRAM_RD;
wire [63:0] ss_DDRAM_DIN;
wire  [7:0] ss_DDRAM_BE;
wire        ss_DDRAM_WE;

// === SS-68000 (ss_m68k): drives save/load through a 68K mini-handler ===
// Triggers from the UI (ss_save/ss_load = pulse). The slot (ss_slot) selects the DDR region.
wire        ss_ui_save = ss_save;
wire        ss_ui_load = ss_load;

// SS module outputs (used above: cpu_din mux, IPL7, reset, pause, cen gating)
wire        ss_din_en, ss_irq, ss_reset, ss_pause, ss_cpu_exec;
wire [15:0] ss_din_data;
wire        ss_do_save, ss_do_load;   // pulses to memory_stream (from ss_m68k)
wire        ss_slot_empty;            // load from a never-written sub-slot -> restore cancelled
wire        ss_restore_done;          // pulse: restore done -> restarts the palette DMA (rebuilds pal_buf)
wire [3:0]  ss_state_dbg;

ss_m68k #(.SS_GLOB_IDX(SS_IDX_GLOBAL)) u_ss_m68k (
	.clk          (clk),
	.ce_cpu       (cpu_cen_g),
	.cpu_word_addr(cpu_addr),          // already a 24-bit byte address
	.cpu_ds_n     (cpu_dsn),
	.cpu_rw       (~cpu_wr),           // 1=read
	.cpu_fc       (cpu_fc),
	.iack_n       (~cpu_iack),
	.cpu_data_out (cpu_wdata),
	.do_save      (ss_ui_save),
	.do_restore   (ss_ui_load),
	.paused_real  (paused_safe_r),   // REAL frame-aligned pause (registered)
	.ss_mem_write (ss_do_save),
	.ss_mem_read  (ss_do_load),
	.ss_busy      (ss_busy),
	.slot_empty   (ss_slot_empty),
	.ss_glob      (ssb[SS_IDX_GLOBAL]),
	.ss_din_en    (ss_din_en),
	.ss_din_data  (ss_din_data),
	.ss_irq       (ss_irq),
	.ss_reset     (ss_reset),
	.ss_pause     (ss_pause),
	.ss_cpu_exec  (ss_cpu_exec),
	.ss_restore_done (ss_restore_done),
	.ss_state_out (ss_state_dbg)
);

// savestate ddr_if <-> raw ss_DDRAM_* signals (ss_ddr declared above, before the MUX)
assign ss_DDRAM_ADDR     = ss_ddr.addr[31:3];
assign ss_DDRAM_DIN      = ss_ddr.wdata;
assign ss_DDRAM_RD       = ss_ddr.read;
assign ss_DDRAM_WE       = ss_ddr.write;
assign ss_DDRAM_BURSTCNT = ss_ddr.burstcnt;
assign ss_DDRAM_BE       = ss_ddr.byteenable;
assign ss_ddr.rdata      = DDRAM_DOUT;
// Until the MUX grants the bus to the SS (ss_ddr_grant), memory_stream must STALL:
// busy=1 (it issues no transactions that would be lost) and rdata_ready=0 (it does not sample
// the game's DOUT). With the grant it sees the real DDRAM_*.
assign ss_ddr.rdata_ready= ss_ddr_grant & DDRAM_DOUT_READY;
assign ss_ddr.busy       = ~ss_ddr_grant | DDRAM_BUSY;

// ssbus/ssb declared at the top (before the first RAM adaptor). Here: mux + master.
ssbus_mux #(.COUNT(SS_NSLAVES)) ss_mux (
	.clk     (clk),
	.slave   (ssbus),
	.masters (ssb)
);

// COUNT = SS_MS_COUNT (power of 2 >= SS_NSLAVES). CHUNK_BITS=$clog2(COUNT). Do NOT use 1
// (CHUNK_BITS=0 breaks the memory_stream bit selects). Chunks beyond SS_NSLAVES stay empty
// (query timeout) → save/load self-consistent. Negligible cost.
// POCKET: requests to the slaves one cycle after address/data (STROBE_DLY), for
// the multicycle 2 of the Pocket SDC on the savestate paths.
save_state_data #(.COUNT(SS_MS_COUNT), .STROBE_DLY(1)) u_save_state (
	.clk        (clk),
	.reset      (reset),
	.ddr        (ss_ddr),
	.read_start (ss_do_load),
	.write_start(ss_do_save),
	.index      (ss_slot),
	.busy       (ss_busy),
	.slot_empty (ss_slot_empty),
	.ssbus      (ssbus)
);

// Sprite renderer: bw_sprites (same engine as Night Slashers / Tattoo), TWO instances,
// one per chip, like the two real DECO52s. Anti-glitch design: parallel
// scan, shadow scan with match FIFO, draw decoupled with prefetch between
// sprites, elastic ring of 12 buffers (consumed only at hblank), latching of the arrivals.
// SPR0_5BPP=0 = BW format (4bpp, 12-bit pxl). The half-adjacent DDR layout
// is applied at download (spr_dst_off). Each instance uses ONLY its own ports:
// the buffers and logic of the other chip are swept away in synthesis.
// sprite_pxl / sprite2_pxl declared above (forward use).
wire [12:0] sprite_pxl13;
assign sprite_pxl = sprite_pxl13[11:0];   // [12] = 0 with SPR0_5BPP=0

bw_sprites #(.SPR0_5BPP(0), .CHIP_ONLY(2'b01)) u_sprites (
	.clk(clk), .reset(reset),
	.sram0_addr(spr_render_addr),
	.sram0_data(spr_render_data),
	.sram1_addr(),
	.sram1_data(16'd0),
	.rom0_addr (sprite_romaddr),
	.rom0_req  (sprite_romreq),
	.rom0_data (sprite_romdata),
	.rom0_valid(sprite_romvalid),
	.rom1_addr (),
	.rom1_req  (),
	.rom1_data (32'd0),
	.rom1_valid(1'b0),
	.rom0_p4_addr (),
	.rom0_p4_req  (),
	.rom0_p4_data (8'd0),
	.rom0_p4_valid(1'b0),
	// RAW coordinates: bw_sprites does the sprite flip itself (flipscreen_spr
	// = ~flip_screen -> x=304-x, y=240-y, mult=-16), in the same space as the
	// MAME bitmap. Passing render_*_flip would flip twice: the two cancel out and
	// the sprites stay upright (shifted by 15 px). The tilegens instead want them
	// flipped: there the flip is done only by this top level.
	.render_x  (render_x), .render_y(render_y),
	.hblank_in (hblank_in),
	.vblank_in (vblank_in),
	.ce_pix    (ce_pix),
	.pause_in  (paused_safe),
	.flip_screen(flip_screen),
	.osd_spr_swap_hl(osd_spr_swap_hl),
	.osd_spr_brev8  (osd_spr_brev8),
	.osd_spr_nibsw  (osd_spr_nibsw),
	.osd_spr_bs_ab  (osd_spr_bs_ab),
	.osd_spr_msb_first   (osd_spr_msb_first),
	.osd_spr_half_inv    (osd_spr_half_inv),
	.osd_spr_half_eff_inv(osd_spr_half_eff_inv),
	.osd_spr_row_inv     (osd_spr_row_inv),
	.osd_spr_plane_inv   (osd_spr_plane_inv),
	.osd_spr_p0_src      (osd_spr_p0_src),
	.osd_spr_p1_src      (osd_spr_p1_src),
	.osd_spr_p2_src      (osd_spr_p2_src),
	.osd_spr_p3_src      (osd_spr_p3_src),
	.osd_spr_w_swap_pos    (osd_spr_w_swap_pos),
	.osd_spr_w_offset_first(osd_spr_w_offset_first),
	.osd_spr_w_code_swap   (osd_spr_w_code_swap),
	.osd_spr_w_offset      (osd_spr_w_offset),
	.pxl0      (sprite_pxl13),
	.pxl1      (),
	.pxl1_alpha()
);

bw_sprites #(.SPR0_5BPP(0), .CHIP_ONLY(2'b10)) u_sprites_c1 (
	.clk(clk), .reset(reset),
	.sram0_addr(),
	.sram0_data(16'd0),
	.sram1_addr(spr2_render_addr),
	.sram1_data(spr2_render_data),
	.rom0_addr (),
	.rom0_req  (),
	.rom0_data (32'd0),
	.rom0_valid(1'b0),
	.rom1_addr (sprite2_romaddr),
	.rom1_req  (sprite2_romreq),
	.rom1_data (sprite2_romdata),
	.rom1_valid(sprite2_romvalid),
	.rom0_p4_addr (),
	.rom0_p4_req  (),
	.rom0_p4_data (8'd0),
	.rom0_p4_valid(1'b0),
	// RAW coordinates: bw_sprites does the sprite flip itself (flipscreen_spr
	// = ~flip_screen -> x=304-x, y=240-y, mult=-16), in the same space as the
	// MAME bitmap. Passing render_*_flip would flip twice: the two cancel out and
	// the sprites stay upright (shifted by 15 px). The tilegens instead want them
	// flipped: there the flip is done only by this top level.
	.render_x  (render_x), .render_y(render_y),
	.hblank_in (hblank_in),
	.vblank_in (vblank_in),
	.ce_pix    (ce_pix),
	.pause_in  (paused_safe),
	.flip_screen(flip_screen),
	.osd_spr_swap_hl(osd_spr_swap_hl),
	.osd_spr_brev8  (osd_spr_brev8),
	.osd_spr_nibsw  (osd_spr_nibsw),
	.osd_spr_bs_ab  (osd_spr_bs_ab),
	.osd_spr_msb_first   (osd_spr_msb_first),
	.osd_spr_half_inv    (osd_spr_half_inv),
	.osd_spr_half_eff_inv(osd_spr_half_eff_inv),
	.osd_spr_row_inv     (osd_spr_row_inv),
	.osd_spr_plane_inv   (osd_spr_plane_inv),
	.osd_spr_p0_src      (osd_spr_p0_src),
	.osd_spr_p1_src      (osd_spr_p1_src),
	.osd_spr_p2_src      (osd_spr_p2_src),
	.osd_spr_p3_src      (osd_spr_p3_src),
	.osd_spr_w_swap_pos    (osd_spr_w_swap_pos),
	.osd_spr_w_offset_first(osd_spr_w_offset_first),
	.osd_spr_w_code_swap   (osd_spr_w_code_swap),
	.osd_spr_w_offset      (osd_spr_w_offset),
	.pxl0      (),
	.pxl1      (sprite2_opq_pxl),
	.pxl1_alpha(sprite2_alp_pxl)
);

// ioctl_wait: back-pressure to the HPS during DDR3 writes.
// Pending wait + post-write stretch counter.
// The stretch gives margin to the clock domain crossing (clk_sys vs DDRAM_CLK) and lets
// refresh/cacheline complete. Without the stretch: race on the req/ack toggle → dropped
// writes → corrupted DDR3 → sprites with holes and monochrome silhouettes.
wire ddr_dl_we_pending = (ddr_dl_we_req != ddr_dl_we_ack);
reg [7:0] ddr_dl_stretch;
reg       ddr_dl_pending_d;
always @(posedge clk) begin
	if (reset) begin
		ddr_dl_stretch   <= 0;
		ddr_dl_pending_d <= 0;
	end else begin
		ddr_dl_pending_d <= ddr_dl_we_pending;
		// Falling edge of pending → load the stretch (64 ck = ~670 ns @ 96 MHz)
		if (ddr_dl_pending_d & ~ddr_dl_we_pending)
			ddr_dl_stretch <= 8'd64;
		else if (ddr_dl_stretch != 0)
			ddr_dl_stretch <= ddr_dl_stretch - 8'd1;
	end
end
// POCKET: both flags are tied low: tile1 is written by sdram_bridge (prog_*) and the
// audio ROM goes to BRAM inside boogwings_audio, so neither adds back-pressure here.
wire pocket_t1_busy = 1'b0;
assign pocket_arom_busy = 1'b0;
assign ioctl_wait = ddr_dl_we_pending | (ddr_dl_stretch != 0) | pocket_t1_busy | pocket_arom_busy;

endmodule
