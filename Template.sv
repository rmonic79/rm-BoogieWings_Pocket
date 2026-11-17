/*  This file is part of BoogieWings_MiSTer.
    GPL-3.
    Based on the MiSTer Template by Sorgelig.
    BoogieWings core: Umberto Parisi (rmonic79).
*/

module emu
(
	input         CLK_50M,
	input         RESET,
	// POCKET: lock of the core PLL, exported to the Pocket framework. core_top uses it for the
	// boot status (Request Status), as in the Analogue template.
	output        POCKET_PLL_LOCKED,
	inout  [45:0] HPS_BUS,   // 46 bits: fb_en/sl are not on the bus (sys_top provides them)
	output        CLK_VIDEO,
	output        CE_PIXEL,
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,
	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER,
	output        VGA_DISABLE,
	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,


	output        LED_USER,
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,
	output  [1:0] BUTTONS,

	input         CLK_AUDIO,
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,
	output  [1:0] AUDIO_MIX,

	inout   [3:0] ADC_BUS,

	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,


	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,


	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS,

	// CRT Adjust (applied in sys_top on MiSTer): OSD values + true VBlank
	output              CRT_ON,
	output signed [4:0] CRT_HSIZE,
	output signed [8:0] CRT_HPOS,
	output signed [5:0] CRT_VSHIFT,
	output signed [5:0] CRT_VSIZE,
	output              CRT_VSMODE,
	output              CRT_VBL
);

///////// Unused ports /////////
assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
// HPS DDRAM driven directly by the game (ddram_4port inside boogwings_top)
assign DDRAM_CLK = clk_sys;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
// Pause: toggle on rising edge of joy[12] (MiSTer built-in pause bit,
// independent of the J1 buttons).
reg pause_toggle;
reg joy_pause_prev;
always @(posedge clk_sys) begin
	if (reset) begin
		pause_toggle <= 1'b0;
		joy_pause_prev <= 1'b0;
	end else begin
		joy_pause_prev <= joy0[12] | joy1[12];
		if ((joy0[12] | joy1[12]) && !joy_pause_prev)
			pause_toggle <= ~pause_toggle;
	end
end
wire pause = pause_toggle;     // joypad only (MiSTer built-in bit 12)
wire clean_pause = status[35]; // overlay off during pause
assign HDMI_FREEZE = 1'b0;  // the pause overlay is rendered in real time: no scaler freeze
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 1;  // signed audio
wire signed [15:0] game_audio_l, game_audio_r;
wire paused_safe;   // from boogwings_top: gates the audio ce counters (frame-aligned gating)
// Savestate: restore values of the ce counters (from boogwings_top) + load pulse.
wire [3:0] ce_audio_cnt_load;
wire [4:0] ce_ym_cnt_load;
wire       ce_ym_toggle_load;
wire [6:0] ce_oki0_cnt_load;
wire [5:0] ce_oki1_cnt_load;
wire       ce_cnt_load_wr;
assign AUDIO_L = game_audio_l;
assign AUDIO_R = game_audio_r;
assign AUDIO_MIX = 0;

// Debug LEDs (core_top leaves them unconnected on the Pocket):
//   LED_DISK  = constant 2'b11
//   LED_POWER = constant 2'b11
//   LED_USER  = constant 0

assign LED_DISK  = 2'b11;
assign LED_POWER = 2'b11;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

// ==== Layer enable OSD ====
// status[30] BG0 (chip0 pf1 = text), [31] BG1 (chip0 pf2), [32] sprite,
// [33] FG0 (chip1 pf1), [34] FG1 (chip1 pf2)
// OSD label "On,Off" → bit=0 = ON, bit=1 = OFF
wire layer_bg0_en = ~status[30];
wire layer_bg1_en = ~status[31];
wire layer_spr_en = ~status[32];
wire layer_fg0_en = ~status[33];
wire layer_fg1_en = ~status[34];

// Refresh rate selector (OSD status[22]): 0=native 57.8Hz (V_TOTAL=269),
// 1=60Hz (V_TOTAL=258) — shortens the vertical blanking, ce_pix /14 unchanged.
wire mode_60hz = status[22];

// BG0/BG1 toggles HARDCODED (hardware-correct values, no OSD).
wire osd_bg0_swap_hl = 1'b0;
wire osd_bg0_brev8   = 1'b1;
wire osd_bg0_nibsw   = 1'b0;
wire osd_bg0_bs_ab   = 1'b1;
wire osd_bg1_swap_hl = 1'b1;
wire osd_bg1_brev8   = 1'b1;
wire osd_bg1_nibsw   = 1'b0;
wire osd_bg1_bs_ab   = 1'b1;
// FG0 + FG1 HARDCODED (default values). No OSD.
wire osd_fg0_swap_hl = 1'b1;
wire osd_fg0_brev8   = 1'b1;
wire osd_fg0_nibsw   = 1'b0;
wire osd_fg0_bs_ab   = 1'b1;
wire osd_fg1_swap_hl = 1'b1;
wire osd_fg1_brev8   = 1'b1;
wire osd_fg1_nibsw   = 1'b0;
wire osd_fg1_bs_ab   = 1'b1;
// Sprite decode: FIXED at 0 (no OSD entry).
wire osd_spr_swap_hl = 1'b0;
wire osd_spr_brev8   = 1'b0;
wire osd_spr_nibsw   = 1'b0;
wire osd_spr_bs_ab   = 1'b0;
// === EXTRA sprite decode permutations — FIXED at 0 (no OSD entry) ===
wire osd_spr_msb_first    = 1'b0;
wire osd_spr_half_inv     = 1'b0;
wire osd_spr_half_eff_inv = 1'b0;
wire osd_spr_row_inv      = 1'b0;
wire osd_spr_plane_inv    = 1'b0;
// Sprite plane byte sources, hardcoded to the hardware-correct values:
// p0=B0, p1=B1, p2=B2, p3=B3
wire [1:0] osd_spr_p0_src = 2'd0;   // B0
wire [1:0] osd_spr_p1_src = 2'd1;   // B1
wire [1:0] osd_spr_p2_src = 2'd2;   // B2
wire [1:0] osd_spr_p3_src = 2'd3;   // B3
// Sprite chip filter (debug): FIXED at 00 (both chips shown).
wire [1:0] osd_spr_chip_filter = 2'b00;
// Wide-sprite w-mode: FIXED at 0 (MAME behaviour, no OSD entry).
wire osd_spr_w_swap_pos     = 1'b0;   // w-mode: 1st/2nd block position as in MAME
wire osd_spr_w_offset_first = 1'b0;   // w-mode: offset on the second block
wire osd_spr_w_code_swap    = 1'b0;   // w-mode: codes in MAME order
wire signed [3:0] osd_spr_w_offset = 4'sd0;   // 0 = MAME -16
// BG1 p4 (plane 4), hardware-validated defaults: byte_pos=[7:0], brev8=ON, bit_shift=OFF.
wire [1:0] osd_bg1_p4_byte_pos  = 2'd0;
wire       osd_bg1_p4_brev8     = 1'b1;
wire       osd_bg1_p4_bit_shift = 1'b0;

`include "build_id.v"
localparam CONF_STR = {
	"BoogieWings;SS3E000000:200000;",
	"-;",
	"O[65:61],Savestate Slot,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32;",
	"R[94],Save state (Alt-F1);",
	"R[95],Restore state (F1);",
	"-;",
	"P1,Video;",
	"P1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P1O[21:19],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer,HV-Integer;",
	"P1O[22],Refresh Rate,Original 57.8Hz,60Hz;",
	// CRT Adjust (applied in sys_top on MiSTer). Status bits taken among those that
	// nothing reads and that never appeared in a published OSD (configs saved under
	// the name "BoogieWings" never wrote them): 1-6, 66-72, 104-115.
	"P1O[72],CRT Adjust,Off,On;",
	"H1P1O[108:104],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[115:109],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[6:1],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[70:66],CRT V-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[71],CRT V-Size Mode,PVM,Cabinet;",
	"-;",
	"O[35],Clean Pause,Off,On;",
	"-;",
	"O[30],Layer BG0,On,Off;",
	"O[31],Layer BG1,On,Off;",
	"O[32],Sprite,On,Off;",
	"O[33],Layer FG0,On,Off;",
	"O[34],Layer FG1,On,Off;",
	"-;",
	"P3,Audio Mixer;",
	"P3O[10:7],FM (YM2151) Gain,Default,Mute,MAME,25%,50%,75%,100%,125%,150%,200%,250%,300%,400%,500%,700%,1000%;",
	"P3O[14:11],OKI0 (Voice/SFX) Gain,Default,Mute,MAME,25%,50%,75%,100%,125%,150%,200%,250%,300%,400%,500%,700%,1000%;",
	"P3O[18:15],OKI1 (Drums) Gain,Default,Mute,MAME,25%,50%,75%,100%,125%,150%,200%,250%,300%,400%,500%,700%,1000%;",
	"P3O[24:23],Presence (Highs),Off,+3 dB,+6 dB,+9 dB;",
	"-;",
	"DIP;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"-;",
	"J1,Fire,Bomb,Start 1P,Start 2P,Coin;",
	"jn,A,B,Start,Select,R;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire [10:0] ps2_key;
wire [15:0] joy0, joy1;
// Raw ioctl from hps_io → download decryptors (de102, deco56) → ioctl_* (decrypted).
// The consumers (bridge/game) use ioctl_*. DECO56 tiles are decrypted and
// remapped during download; everything else passes through.
wire        ioctl_download_raw;
wire [15:0] ioctl_index_raw;
wire        ioctl_wr_raw;
wire [26:0] ioctl_addr_raw;
wire [15:0] ioctl_dout_raw;

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire [15:0] ioctl_dout;   // 16-bit: WIDE=1
wire        ioctl_wait_sdram;
wire        ioctl_wait_audio;
// The decryptors remap inline with no buffering: hps_io is paced by the bridge
// (ioctl_wait_sdram) and the game (ioctl_wait_audio). No extra wait.
wire        ioctl_wait = ioctl_wait_sdram | ioctl_wait_audio;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),
	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.status_menumask({14'd0, ~status[72], 1'b0}),   // H1: hide the CRT entries when CRT Adjust=Off
	.ps2_key(ps2_key),
	.joystick_0(joy0),
	.joystick_1(joy1),
	.ioctl_download(ioctl_download_raw),
	.ioctl_index(ioctl_index_raw),
	.ioctl_wr(ioctl_wr_raw),
	.ioctl_addr(ioctl_addr_raw),
	.ioctl_dout(ioctl_dout_raw),
	.ioctl_wait(ioctl_wait)
);

// === Savestate UI: save/load triggers from keys (Alt+F1-F4 / F1-F4), gamepad, OSD ===
wire        ss_save, ss_load;
wire [4:0]  ss_slot;   // 32 slots: [4:3]=region (file .ss1-.ss4), [2:0]=sub-slot
// Gamepad bits: SELECT (joy[13]) as "SS modifier" + directions; OSD via status R[94]/R[95].
wire [15:0] joy_all = joy0 | joy1;
savestate_ui #(.INFO_TIMEOUT_BITS(25)) u_ss_ui (
	.clk         (clk_sys),
	.ps2_key     (ps2_key),
	.allow_ss    (1'b1),
	.joySS       (joy_all[13]),   // Select
	.joyRight    (joy_all[0]),
	.joyLeft     (joy_all[1]),
	.joyDown     (joy_all[2]),
	.joyUp       (joy_all[3]),
	.joyStart    (joy_all[12]),
	.joyRewind   (1'b0),
	.rewindEnable(1'b0),
	.status_slot (status[65:61]),
	.autoincslot (1'b0),
	.OSD_saveload(status[95:94]),  // R[94]=save, R[95]=restore
	.ss_save     (ss_save),
	.ss_load     (ss_load),
	.ss_info_req (),
	.ss_info     (),
	.statusUpdate(),
	.selected_slot(ss_slot)
);

// ── DOWNLOAD: de102 and deco56 in PARALLEL + PRIORITY mux + register ─────────
// Timing: chaining the two decryptors in SERIES (de102 -> deco56) with the
// consumer decode in the same cycle fails timing on ioctl_addr/index -> dsw_port.
//
// The two stages work on DISJOINT ranges and each one produces addresses INSIDE
// its own range: de102 OP [0,0x100000) and DATA [0x1130000,0x1230000) (base + 2*i,
// i < 2^19); deco56 [0x110000,0x830000) (remap within the 0x800-word block).
// In series each one would pass through untouched what the other produced: the
// series would only add delay. de102 has no state and no flush -> no coupling.
wire [26:0] a_102;
wire [15:0] d_102;
wire        rmp_102;

de102_ioctl_decrypt u_de102_dl (
	.clk               (clk_sys),
	.ioctl_addr_in     (ioctl_addr_raw),
	.ioctl_dout_in     (ioctl_dout_raw),
	.ioctl_wr_in       (ioctl_wr_raw),
	.ioctl_index_in    (ioctl_index_raw),
	.ioctl_download_in (ioctl_download_raw),
	.ioctl_addr_out    (a_102),
	.ioctl_dout_out    (d_102),
	.ioctl_wr_out      (),
	.ioctl_index_out   (),
	.ioctl_download_out(),
	.remap_out         (rmp_102)
);

// ── REGISTER STAGE on the download ADDRESS/DATA only ─────────────────────────
// hps_io (sys/hps_io.sv, FIO_FILE_TX_DAT) updates ioctl_addr/ioctl_dout and raises
// `wr` on the same edge; `ioctl_wr <= wr` arrives one edge LATER. The consumer
// samples two edges after launch: the registered copy holds the same value at
// the instant of the strobe. Consumers: bridge (dl_accept/prog_wr on ioctl_wr),
// dsw_port, audio ROM and DDR (ioctl_wr edge).
// `ioctl_wr` is NOT registered: prog_wr, ioctl_wait and the bridge acceptance
// are unchanged (registering the whole STREAM shifts the pacing -> lost words).
// ioctl_index/ioctl_download stay RAW: registering them would add a dependency
// on the protocol (index changing with a strobe in flight).
reg [26:0] ioctl_addr_r;
reg [15:0] ioctl_dout_r;
// POCKET: the same register, placed BEFORE the mux and the deco56 decryption
// (deco56_ioctl_decrypt_reg: tables in M10K with synchronous read). Values are
// identical cycle by cycle: reg(mux(x)) = mux(reg(x)).
wire [26:0] a_56_r;
wire [15:0] d_56_r;
wire        rmp_56_r;
deco56_ioctl_decrypt_reg u_deco56_dl (
	.clk               (clk_sys),
	.ioctl_addr_in     (ioctl_addr_raw),
	.ioctl_dout_in     (ioctl_dout_raw),
	.ioctl_index_in    (ioctl_index_raw),
	.ioctl_download_in (ioctl_download_raw),
	.ioctl_addr_out_r  (a_56_r),
	.ioctl_dout_out_r  (d_56_r),
	.remap_out_r       (rmp_56_r)
);
reg [26:0] a_102_r, addr_raw_r;
reg [15:0] d_102_r, dout_raw_r;
reg        rmp_102_r;
always @(posedge clk_sys) begin
	a_102_r    <= a_102;
	d_102_r    <= d_102;
	rmp_102_r  <= rmp_102;
	addr_raw_r <= ioctl_addr_raw;
	dout_raw_r <= ioctl_dout_raw;
end
always @(*) begin
	ioctl_addr_r = rmp_102_r ? a_102_r : rmp_56_r ? a_56_r : addr_raw_r;
	ioctl_dout_r = rmp_102_r ? d_102_r : rmp_56_r ? d_56_r : dout_raw_r;
end

assign ioctl_addr     = ioctl_addr_r;
assign ioctl_dout     = ioctl_dout_r;
assign ioctl_wr       = ioctl_wr_raw;
assign ioctl_index    = ioctl_index_raw;
assign ioctl_download = ioctl_download_raw;

// --- BoogieWings INPUT mapping (MAME boogwing.cpp:561-633 INPUT_PORTS_START) ---
// MiSTer joy bit layout (MiSTer convention):
//   [0]=Right, [1]=Left, [2]=Down, [3]=Up
//   [4]=A (FIRE/BTN1), [5]=B (BOMB/BTN2), [6]=X (SPECIAL/BTN3)
//   [10]=Start, [11]=Coin
//
// INPUTS port (MAME "INPUTS", 16-bit, all active LOW):
//   bit 0: P1 UP    bit 1: P1 DOWN  bit 2: P1 LEFT   bit 3: P1 RIGHT
//   bit 4: P1 BTN1  bit 5: P1 BTN2  bit 6: P1 BTN3   bit 7: P1 START
//   bit 8..15 same for P2
wire [15:0] inputs_port = {
	/* bit 15 */ ~joy1[10],   // P2 START
	/* bit 14 */ ~joy1[6],    // P2 BTN3
	/* bit 13 */ ~joy1[5],    // P2 BTN2
	/* bit 12 */ ~joy1[4],    // P2 BTN1
	/* bit 11 */ ~joy1[0],    // P2 RIGHT
	/* bit 10 */ ~joy1[1],    // P2 LEFT
	/* bit 9  */ ~joy1[2],    // P2 DOWN
	/* bit 8  */ ~joy1[3],    // P2 UP
	/* bit 7  */ ~joy0[10],   // P1 START
	/* bit 6  */ ~joy0[6],    // P1 BTN3
	/* bit 5  */ ~joy0[5],    // P1 BTN2
	/* bit 4  */ ~joy0[4],    // P1 BTN1
	/* bit 3  */ ~joy0[0],    // P1 RIGHT
	/* bit 2  */ ~joy0[1],    // P1 LEFT
	/* bit 1  */ ~joy0[2],    // P1 DOWN
	/* bit 0  */ ~joy0[3]     // P1 UP
};

// SYSTEM port (MAME "SYSTEM", 16-bit):
//   bit 0: COIN1     (active LOW)
//   bit 1: COIN2     (active LOW)
//   bit 2: SERVICE1  (active LOW)
//   bit 3: VBLANK    (active HIGH — from the screen device)
//   bit 4..15: unused (idle HIGH)
wire [15:0] system_port = {
	12'hFFF,                  // bit 15..4 unused
	VBlank,                   // bit 3 VBLANK (active HIGH in MAME → 1 during vblank)
	1'b1,                     // bit 2 SERVICE1 idle (no service button mapped yet)
	~joy1[11],                // bit 1 COIN2
	~joy0[11]                 // bit 0 COIN1
};

// DSW port — loaded from MRA via ioctl (index 254)
// Active-LOW: default "FF,FF" = all OFF = all 1s
reg [15:0] dsw_port = 16'hFFFF;
always @(posedge clk_sys)
	if (ioctl_wr && (ioctl_index == 16'd254) && !ioctl_addr[26:1])
		dsw_port <= ioctl_dout;

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;
wire pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.locked(pll_locked)
);
assign POCKET_PLL_LOCKED = pll_locked;

// Game reset: includes download (game held in reset while ROM loads)
// + hold counter: keeps reset high for ~2^17 cycles (~1.4ms at 96MHz) after the
// cause drops, to give SDRAM/clear FSM/PLL time to settle.
wire reset_cause = RESET | status[0] | buttons[1] | ~pll_locked | ioctl_download;
reg [16:0] reset_hold_cnt = 17'h1FFFF;  // starts loaded at power-on
always @(posedge clk_sys) begin
	if (reset_cause) reset_hold_cnt <= 17'h1FFFF;  // reload while a cause is present
	else if (reset_hold_cnt != 17'd0) reset_hold_cnt <= reset_hold_cnt - 17'd1;
end
// POCKET: the same reset, but from a register instead of the 17-bit compare
// (huge fanout, timing on the Pocket). reset_r(t+1) = cause(t) | cnt(t) > 1, which
// is exactly cnt(t+1) != 0: identical cycle by cycle.
reg  reset_r = 1'b1;
always @(posedge clk_sys) reset_r <= reset_cause | (reset_hold_cnt > 17'd1);
wire reset = reset_r;
// Bridge reset: ONLY pll_locked — bridge must run during download, before RESET drops
wire bridge_reset = ~pll_locked;
// Video reset: ONLY pll_locked — CRT needs sync always, even during RESET and download
wire video_reset = ~pll_locked;

///////////////////////   SDRAM (jtframe_sdram64, 4 parallel banks)  //
//
// Physical bank mapping:
//   ba0 = FG0  (chip1.pf1, BG2 alpha)  — parallel fetch
//   ba1 = FG1  (chip1.pf2, BG2 base)   — parallel fetch
//   ba2 = Main CPU 68K (op + data view)
//   ba3 = BG1 (chip0.pf2, 5bpp) + POCKET: text (chip0.pf1, tile1)
//
// Download via prog_*: the bridge selects prog_ba from ioctl_addr.
// BAx_LEN=16 (1 word per fetch), CL=2, MISTER mode.
///////////////////////////////////////////////////////////////////////

localparam SDRAM_AW = 22;

// Per-bank request signals (driven by bridge)
wire [SDRAM_AW-1:0] ba0_addr, ba1_addr, ba2_addr, ba3_addr;
wire [3:0]          ba_rd, ba_wr;
wire [15:0]         ba0_din, ba1_din, ba2_din, ba3_din;
wire [1:0]          ba0_dsn, ba1_dsn, ba2_dsn, ba3_dsn;
wire [3:0]          ba_ack, ba_rdy, ba_dst, ba_dok;
wire [15:0]         sdram_dout_jt;

// Program (download) interface
wire                prog_en;
wire [SDRAM_AW-1:0] prog_addr;
wire [1:0]          prog_ba;
wire                prog_rd, prog_wr;
wire [15:0]         prog_din;
wire [1:0]          prog_dsn;
wire                prog_ack, prog_rdy, prog_dst, prog_dok;

// Refresh trigger: one pulse per HBlank/VBlank rising edge is enough — the refresh module accumulates debt.
reg vblank_d, hblank_d;
always @(posedge clk_sys) begin vblank_d <= VBlank; hblank_d <= HBlank; end
wire rfsh_pulse = (HBlank & ~hblank_d) | (VBlank & ~vblank_d);

// init signal (sdram_init / ready): jtframe drives `init` as an output that stays high during init.
// The bridge uses sdram_ready, so ready = ~init.
wire sdram_init_w;
wire sdram_ready = ~sdram_init_w;

jtframe_sdram64 #(
	.AW           ( SDRAM_AW ),
	.HF           ( 1        ),     // 96 MHz operation
	.EMRS         ( 1        ),     // POCKET: mobile SDRAM, Extended Mode Register (Analogue docs)
	.SHIFTED      ( 0        ),
	.BA0_LEN      ( 16       ),     // single-word burst (1 word per fetch)
	.BA1_LEN      ( 16       ),
	.BA2_LEN      ( 16       ),
	.BA3_LEN      ( 16       ),
	.PROG_LEN     ( 16       ),     // program writes 1 word
	.MISTER       ( 1        ),
	.BA1_WEN      ( 0        ),
	.BA2_WEN      ( 0        ),
	.BA3_WEN      ( 0        ),
	.BA0_AUTOPRECH( 0        ),
	.BA1_AUTOPRECH( 0        ),
	.BA2_AUTOPRECH( 0        ),
	.BA3_AUTOPRECH( 0        )
) u_sdram_jt (
	.rst        ( ~pll_locked ),
	.clk        ( clk_sys     ),
	.init       ( sdram_init_w ),

	.ba0_addr   ( ba0_addr ),
	.ba1_addr   ( ba1_addr ),
	.ba2_addr   ( ba2_addr ),
	.ba3_addr   ( ba3_addr ),

	.rd         ( ba_rd    ),
	.wr         ( ba_wr    ),
	.ba0_din    ( ba0_din  ),
	.ba0_dsn    ( ba0_dsn  ),
	.ba1_din    ( ba1_din  ),
	.ba1_dsn    ( ba1_dsn  ),
	.ba2_din    ( ba2_din  ),
	.ba2_dsn    ( ba2_dsn  ),
	.ba3_din    ( ba3_din  ),
	.ba3_dsn    ( ba3_dsn  ),

	.rdy        ( ba_rdy ),
	.ack        ( ba_ack ),
	.dst        ( ba_dst ),
	.dok        ( ba_dok ),

	// Program (ROM-load) interface
	.prog_en    ( prog_en   ),
	.prog_addr  ( prog_addr ),
	.prog_ba    ( prog_ba   ),
	.prog_rd    ( prog_rd   ),
	.prog_wr    ( prog_wr   ),
	.prog_din   ( prog_din  ),
	.prog_dsn   ( prog_dsn  ),
	.prog_rdy   ( prog_rdy  ),
	.prog_dst   ( prog_dst  ),
	.prog_dok   ( prog_dok  ),
	.prog_ack   ( prog_ack  ),

	// SDRAM pins
	.sdram_dq   ( SDRAM_DQ   ),
	.sdram_a    ( SDRAM_A    ),
	.sdram_dqml ( SDRAM_DQML ),
	.sdram_dqmh ( SDRAM_DQMH ),
	.sdram_nwe  ( SDRAM_nWE  ),
	.sdram_ncas ( SDRAM_nCAS ),
	.sdram_nras ( SDRAM_nRAS ),
	.sdram_ncs  ( SDRAM_nCS  ),
	.sdram_ba   ( SDRAM_BA   ),
	.sdram_cke  ( SDRAM_CKE  ),

	// Shared read data bus
	.dout       ( sdram_dout_jt ),
	.rfsh       ( rfsh_pulse    )
);

// POCKET: SDRAM_CLK in phase with clk_sys (0°), as in jotego's Pocket target
// for this same controller (jtframe_sdram64, HF=1, SHIFTED=0, 96 MHz): same
// chip, same pins and same electrical settings (identical qsf). On the Pocket
// the SDRAM is soldered next to the FPGA; the 180° shift is needed on MiSTer,
// where the SDRAM is on a separate board.
assign SDRAM_CLK = clk_sys;

///////////////////////   BRIDGE   ///////////////////////////////

// Game ↔ bridge wiring (level protocol).
wire [23:0] game_main_addr;
wire        game_main_req;
wire [15:0] game_main_data;
wire        game_main_ready;

// Main ROM: the opcode and data views are separate copies in SDRAM
// (selected by main_is_opcode), so there is no ROM cache in between.
wire [23:0] bridge_main_addr;
wire        bridge_main_req;
wire [15:0] bridge_main_data;
wire        bridge_main_ready;
wire        game_main_is_opcode;

// No cache: the CPU talks directly to the bridge.
assign bridge_main_addr = game_main_addr;
assign bridge_main_req  = game_main_req;
assign game_main_data   = bridge_main_data;
assign game_main_ready  = bridge_main_ready;

// =========================================================================
// Bridge for jtframe_sdram64 (4 truly parallel banks).
// Mapping:
//   FG0 (chip1.pf1)  → ba0 (fg0_* interface)
//   FG1 (chip1.pf2)  → ba1 (fg1_* interface)
//   Main 68K op+data → ba2 (main_* interface)
//   BG1 + text       → ba3 (bg1_* and txt_* interfaces)
//   Download         → prog_* (prog_ba selected by ioctl range)
// =========================================================================
// FG0 (chip1.pf1) and FG1 (chip1.pf2) wired DIRECTLY from the game to the bridge — no arbiter.
wire [23:0] game_fg0_addr_w;
wire [2:0]  game_fg0_rid_w;
wire        game_fg0_req_w;
wire [31:0] game_fg0_data_w;
wire        game_fg0_valid_w;
wire [23:0] game_fg1_addr_w;
wire [2:0]  game_fg1_rid_w;
wire        game_fg1_req_w;
wire [31:0] game_fg1_data_w;
wire        game_fg1_valid_w;

// BG1 (chip0.pf2, 5bpp) — ba3 SDRAM with a dedicated p4 channel
wire [23:0] game_bg1_addr_w;
wire        game_bg1_req_w;
wire [31:0] game_bg1_data_w;
wire        game_bg1_valid_w;
wire        game_bg1_p4_req_w;
wire  [7:0] game_bg1_p4_data_w;
wire        game_bg1_p4_valid_w;
// POCKET: text (tile1) in ba3
wire [23:0] game_txt_addr_w;
wire        game_txt_req_w;
wire [31:0] game_txt_data_w;
wire        game_txt_valid_w;


sdram_bridge bridge
(
	.clk(clk_sys),
	.reset(bridge_reset),
	.sdram_ready(sdram_ready),

	// HPS download
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait_sdram),

	// FG0 (chip1.pf1) — ba0
	.fg0_byte_addr  (game_fg0_addr_w),
	.fg0_region_id  (game_fg0_rid_w),
	.fg0_req        (game_fg0_req_w),
	.fg0_data       (game_fg0_data_w),
	.fg0_valid      (game_fg0_valid_w),

	// FG1 (chip1.pf2) — ba1
	.fg1_byte_addr  (game_fg1_addr_w),
	.fg1_region_id  (game_fg1_rid_w),
	.fg1_req        (game_fg1_req_w),
	.fg1_data       (game_fg1_data_w),
	.fg1_valid      (game_fg1_valid_w),

	// Main CPU 68K (op + data view) — ba2
	.main_byte_addr (bridge_main_addr),
	.main_is_opcode (game_main_is_opcode),
	.main_req       (bridge_main_req),
	.main_data      (bridge_main_data),
	.main_ready     (bridge_main_ready),

	// BG1 (chip0.pf2, 5bpp) — ba3
	.bg1_byte_addr  (game_bg1_addr_w),
	.bg1_req        (game_bg1_req_w),
	.bg1_p4_req     (game_bg1_p4_req_w),
	.bg1_data       (game_bg1_data_w),
	.bg1_valid      (game_bg1_valid_w),
	.bg1_p4_data    (game_bg1_p4_data_w),
	.bg1_p4_valid   (game_bg1_p4_valid_w),
	// POCKET: text (chip0.pf1) - ba3 after BG1
	.txt_byte_addr  (game_txt_addr_w),
	.txt_req        (game_txt_req_w),
	.txt_data       (game_txt_data_w),
	.txt_valid      (game_txt_valid_w),

	// jtframe_sdram64 per-bank interface (4 in parallel)
	.ba0_addr (ba0_addr), .ba0_din(ba0_din), .ba0_dsn(ba0_dsn),
	.ba1_addr (ba1_addr), .ba1_din(ba1_din), .ba1_dsn(ba1_dsn),
	.ba2_addr (ba2_addr), .ba2_din(ba2_din), .ba2_dsn(ba2_dsn),
	.ba3_addr (ba3_addr), .ba3_din(ba3_din), .ba3_dsn(ba3_dsn),
	.ba_rd    (ba_rd),
	.ba_wr    (ba_wr),
	.ba_ack   (ba_ack),
	.ba_rdy   (ba_rdy),
	.ba_dst   (ba_dst),
	.ba_dok   (ba_dok),
	.sdram_dout (sdram_dout_jt),

	// Program (download) interface
	.prog_en   (prog_en),
	.prog_addr (prog_addr),
	.prog_ba   (prog_ba),
	.prog_rd   (prog_rd),
	.prog_wr   (prog_wr),
	.prog_din  (prog_din),
	.prog_dsn  (prog_dsn),
	.prog_ack  (prog_ack),
	.prog_rdy  (prog_rdy),
	.prog_dst  (prog_dst),
	.prog_dok  (prog_dok)
);

///////////////////////   GAME   ///////////////////////////////

// ce_pix: 96 MHz / 14 = 6.857 MHz, INTEGER divider (UNIFORM, no jitter).
// The 57.8Hz refresh comes from a reduced V_TOTAL (vcnt wrap), NOT from an accumulator.
reg [3:0] ce_pix_cnt;
reg       ce_pix_r;
always @(posedge clk_sys) begin
	if (video_reset) begin
		ce_pix_cnt <= 4'd0;
		ce_pix_r   <= 1'b0;
	end else if (ce_pix_cnt == 4'd13) begin
		ce_pix_cnt <= 4'd0;
		ce_pix_r   <= 1'b1;
	end else begin
		ce_pix_cnt <= ce_pix_cnt + 4'd1;
		ce_pix_r   <= 1'b0;
	end
end
wire ce_pix = ce_pix_r;

// ce_audio: 96 MHz / 12 = 8 MHz (H6280 target = SOUND_XTAL/4 ≈ 8.055 MHz)
// NOTE: uses `reset`, not `video_reset`, to avoid pitch glitches when pll_locked toggles
reg [3:0] ce_audio_cnt;
reg       ce_audio_r;
always @(posedge clk_sys) begin
	if (reset) begin
		ce_audio_cnt <= 4'd0;
		ce_audio_r   <= 1'b0;
	end else begin
		ce_audio_r <= 1'b0;
		if (ce_cnt_load_wr) begin
			ce_audio_cnt <= ce_audio_cnt_load;   // phase restore (transparent: load_wr=0 outside a savestate load)
		end else if (~paused_safe) begin
			if (ce_audio_cnt == 4'd11) begin
				ce_audio_cnt <= 4'd0;
				ce_audio_r   <= 1'b1;
			end else begin
				ce_audio_cnt <= ce_audio_cnt + 4'd1;
			end
		end
	end
end
wire ce_audio = ce_audio_r;

// ce_ym: 96 MHz / 27 ≈ 3.555 MHz (YM2151 target = SOUND_XTAL/9 ≈ 3.580 MHz)
// ce_ym_p1: half rate (= cen_p1 jt51)
reg [4:0] ce_ym_cnt;
reg       ce_ym_r, ce_ym_p1_r;
reg       ce_ym_toggle;
always @(posedge clk_sys) begin
	if (reset) begin
		ce_ym_cnt    <= 5'd0;
		ce_ym_r      <= 1'b0;
		ce_ym_p1_r   <= 1'b0;
		ce_ym_toggle <= 1'b0;
	end else begin
		ce_ym_r    <= 1'b0;
		ce_ym_p1_r <= 1'b0;
		if (ce_cnt_load_wr) begin
			ce_ym_cnt    <= ce_ym_cnt_load;       // phase + toggle restore (half-rate jt51 cen_p1)
			ce_ym_toggle <= ce_ym_toggle_load;
		end else if (~paused_safe) begin
			if (ce_ym_cnt == 5'd26) begin
				ce_ym_cnt    <= 5'd0;
				ce_ym_r      <= 1'b1;
				ce_ym_p1_r   <= ce_ym_toggle;     // pulses on every other ce_ym
				ce_ym_toggle <= ~ce_ym_toggle;
			end else begin
				ce_ym_cnt <= ce_ym_cnt + 5'd1;
			end
		end
	end
end
wire ce_ym    = ce_ym_r;
wire ce_ym_p1 = ce_ym_p1_r;

// ce_oki0: 96 MHz / 95 ≈ 1.0105 MHz (OKI #0 target 1.0069 MHz, error +0.36%)
reg [6:0] ce_oki0_cnt;
reg       ce_oki0_r;
always @(posedge clk_sys) begin
	if (reset) begin
		ce_oki0_cnt <= 7'd0;
		ce_oki0_r   <= 1'b0;
	end else begin
		ce_oki0_r <= 1'b0;
		if (ce_cnt_load_wr) begin
			ce_oki0_cnt <= ce_oki0_cnt_load;     // phase restore
		end else if (~paused_safe) begin
			if (ce_oki0_cnt == 7'd94) begin
				ce_oki0_cnt <= 7'd0;
				ce_oki0_r   <= 1'b1;
			end else begin
				ce_oki0_cnt <= ce_oki0_cnt + 7'd1;
			end
		end
	end
end
wire ce_oki0 = ce_oki0_r;

// ce_oki1: 96 MHz / 48 = 2.000 MHz (OKI #1 target 2.0138 MHz, error -0.69%)
reg [5:0] ce_oki1_cnt;
reg       ce_oki1_r;
always @(posedge clk_sys) begin
	if (reset) begin
		ce_oki1_cnt <= 6'd0;
		ce_oki1_r   <= 1'b0;
	end else begin
		ce_oki1_r <= 1'b0;
		if (ce_cnt_load_wr) begin
			ce_oki1_cnt <= ce_oki1_cnt_load;     // phase restore
		end else if (~paused_safe) begin
			if (ce_oki1_cnt == 6'd47) begin
				ce_oki1_cnt <= 6'd0;
				ce_oki1_r   <= 1'b1;
			end else begin
				ce_oki1_cnt <= ce_oki1_cnt + 6'd1;
			end
		end
	end
end
wire ce_oki1 = ce_oki1_r;

// OSD audio gain decoder: 4 bit → gain 4.4 fixed point
// 0=Default 1=Mute 2=MAME 3=25% 4=50% 5=75% 6=100% 7=125% 8=150% 9=200%
// 10=250% 11=300% 12=400% 13=500% 14=700% 15=1000%
// The % is a scaling of the Default (= base value of each chip).
function [11:0] osd_mul12;
	input [3:0] sel;
	case (sel)
		4'd0:  osd_mul12 = 12'd256;   // Default (placeholder, handled below)
		4'd1:  osd_mul12 = 12'd0;     // Mute
		4'd2:  osd_mul12 = 12'd0;     // MAME (placeholder, handled below)
		4'd3:  osd_mul12 = 12'd64;    // 25%  (= ×0.25)
		4'd4:  osd_mul12 = 12'd128;   // 50%
		4'd5:  osd_mul12 = 12'd192;   // 75%
		4'd6:  osd_mul12 = 12'd256;   // 100%
		4'd7:  osd_mul12 = 12'd320;   // 125%
		4'd8:  osd_mul12 = 12'd384;   // 150%
		4'd9:  osd_mul12 = 12'd512;   // 200%
		4'd10: osd_mul12 = 12'd640;   // 250%
		4'd11: osd_mul12 = 12'd768;   // 300%
		4'd12: osd_mul12 = 12'd1024;  // 400%
		4'd13: osd_mul12 = 12'd1280;  // 500%
		4'd14: osd_mul12 = 12'd1792;  // 700%
		4'd15: osd_mul12 = 12'd2560;  // 1000%
	endcase
endfunction
// Defaults tuned on hardware:
//   FM=0x08 (0.5), OKI0=0xFF (15.94, = saturation max), OKI1=0x80 (8.0)
// Exact MAME values: FM=0x05 (0.32), OKI0=0x09 (0.56), OKI1=0x02 (0.12)
function [7:0] osd_gain;
	input [3:0] sel;
	input [7:0] def_g;
	input [7:0] mame_g;
	reg [19:0] scaled;   // def_g (8-bit) × mul12 (12-bit) → 20-bit
	begin
		case (sel)
			4'd0: osd_gain = def_g;
			4'd1: osd_gain = 8'h00;
			4'd2: osd_gain = mame_g;
			default: begin
				scaled = def_g * osd_mul12(sel);
				// >>8 = back to scale (mul12 100% = 256). Saturates to 8 bits.
				osd_gain = (scaled[19:8] > 12'hFF) ? 8'hFF : scaled[15:8];
			end
		endcase
	end
endfunction
// OSD selections passed straight to the audio block (Default/MAME values hardcoded inside).
wire [3:0] osd_sel_fm   = status[10:7];
wire [3:0] osd_sel_oki0 = status[14:11];
wire [3:0] osd_sel_oki1 = status[18:15];
wire [1:0] osd_presence = status[24:23];

wire [9:0]  render_x;
wire [8:0]  render_y;

// BoogieWings game top (Data East 1992)
//   M68K main + H6280 sound + 2× DECO16IC + 2× DECO_SPRITE + DECO_ACE +
//   DECO104 + YM2151 + 2× OKIM6295
wire [23:0] game_rgb;

boogwings_top game
(
	.clk(clk_sys),
	.reset(reset),
	.pause(pause),

	// Savestate trigger (from savestate_ui)
	.ss_save(ss_save),
	.ss_load(ss_load),
	.ss_slot(ss_slot),

	.inputs_port(inputs_port),
	.system_port(system_port),
	.dsw_port(dsw_port),

	// SDRAM ROM (via bridge)
	.main_rom_addr(game_main_addr),
	.main_rom_is_opcode(game_main_is_opcode),
	.main_rom_req(game_main_req),
	.main_rom_rdata(game_main_data),
	.main_rom_ready(game_main_ready),

	// FG0/FG1 direct — no arbiter, each one on its own SDRAM bank
	.tilerom_fg0_addr      (game_fg0_addr_w),
	.tilerom_fg0_region_id (game_fg0_rid_w),
	.tilerom_fg0_req       (game_fg0_req_w),
	.tilerom_fg0_data      (game_fg0_data_w),
	.tilerom_fg0_valid     (game_fg0_valid_w),
	.tilerom_fg1_addr      (game_fg1_addr_w),
	.tilerom_fg1_region_id (game_fg1_rid_w),
	.tilerom_fg1_req       (game_fg1_req_w),
	.tilerom_fg1_data      (game_fg1_data_w),
	.tilerom_fg1_valid     (game_fg1_valid_w),

	// BG1 chip0.pf2 5bpp → ba3 SDRAM, dedicated p4 channel (no tile_perm)
	.tilerom_bg1_addr      (game_bg1_addr_w),
	.tilerom_bg1_req       (game_bg1_req_w),
	.tilerom_bg1_data      (game_bg1_data_w),
	.tilerom_bg1_valid     (game_bg1_valid_w),
	.tilerom_bg1_p4_req    (game_bg1_p4_req_w),
	.tilerom_bg1_p4_data   (game_bg1_p4_data_w),
	.tilerom_bg1_p4_valid  (game_bg1_p4_valid_w),

	// ioctl download
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait_audio),

	// Video
	.render_x(render_x),
	.render_y({1'b0, render_y}),  // boogwings_top render_y is 10-bit
	.hblank_in(HBlank),
	.vblank_in(VBlank),
	.ce_pix(ce_pix),
	.ce_audio(ce_audio),
	.ce_ym(ce_ym),
	.ce_ym_p1(ce_ym_p1),
	.ce_oki0(ce_oki0),
	.ce_oki1(ce_oki1),
	// Savestate of the ce counter phases: values out (save) + load values in (restore)
	.ce_audio_cnt_in(ce_audio_cnt),
	.ce_ym_cnt_in(ce_ym_cnt),
	.ce_ym_toggle_in(ce_ym_toggle),
	.ce_oki0_cnt_in(ce_oki0_cnt),
	.ce_oki1_cnt_in(ce_oki1_cnt),
	.ce_audio_cnt_load(ce_audio_cnt_load),
	.ce_ym_cnt_load(ce_ym_cnt_load),
	.ce_ym_toggle_load(ce_ym_toggle_load),
	.ce_oki0_cnt_load(ce_oki0_cnt_load),
	.ce_oki1_cnt_load(ce_oki1_cnt_load),
	.ce_cnt_load_wr(ce_cnt_load_wr),
	.osd_sel_fm  (osd_sel_fm),
	.osd_sel_oki0(osd_sel_oki0),
	.osd_sel_oki1(osd_sel_oki1),
	.osd_presence(osd_presence),
	.rgb_out(game_rgb),

	// Layer enable OSD
	.layer_bg0_en(layer_bg0_en),
	.layer_bg1_en(layer_bg1_en),
	.layer_spr_en(layer_spr_en),
	.layer_fg0_en(layer_fg0_en),
	.layer_fg1_en(layer_fg1_en),

	// Tile permutation toggles (16 = 4 perm × 4 layer + sprite)
	.osd_bg0_swap_hl(osd_bg0_swap_hl),
	.osd_bg0_brev8  (osd_bg0_brev8),
	.osd_bg0_nibsw  (osd_bg0_nibsw),
	.osd_bg0_bs_ab  (osd_bg0_bs_ab),
	.osd_bg1_swap_hl(osd_bg1_swap_hl),
	.osd_bg1_brev8  (osd_bg1_brev8),
	.osd_bg1_nibsw  (osd_bg1_nibsw),
	.osd_bg1_bs_ab  (osd_bg1_bs_ab),
	.osd_fg0_swap_hl(osd_fg0_swap_hl),
	.osd_fg0_brev8  (osd_fg0_brev8),
	.osd_fg0_nibsw  (osd_fg0_nibsw),
	.osd_fg0_bs_ab  (osd_fg0_bs_ab),
	.osd_fg1_swap_hl(osd_fg1_swap_hl),
	.osd_fg1_brev8  (osd_fg1_brev8),
	.osd_fg1_nibsw  (osd_fg1_nibsw),
	.osd_fg1_bs_ab  (osd_fg1_bs_ab),
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
	.osd_spr_chip_filter (osd_spr_chip_filter),
	.osd_spr_w_swap_pos    (osd_spr_w_swap_pos),
	.osd_spr_w_offset_first(osd_spr_w_offset_first),
	.osd_spr_w_code_swap   (osd_spr_w_code_swap),
	.osd_spr_w_offset      (osd_spr_w_offset),

	// BG1 p4 (plane 4 mbd-02) permutation toggles
	.osd_bg1_p4_byte_pos (osd_bg1_p4_byte_pos),
	.osd_bg1_p4_brev8    (osd_bg1_p4_brev8),
	.osd_bg1_p4_bit_shift(osd_bg1_p4_bit_shift),

	// Audio
	.audio_l(game_audio_l),
	.audio_r(game_audio_r),
	.paused_safe(paused_safe),

	// DDRAM HPS pins
	.DDRAM_CLK(clk_sys),
	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE)
	,
	.txt_rom_addr (game_txt_addr_w),
	.txt_rom_req  (game_txt_req_w),
	.txt_rom_data (game_txt_data_w),
	.txt_rom_valid(game_txt_valid_w)
);

///////////////////////   VIDEO   ///////////////////////////////

// BoogieWings video timing: 320×240 60Hz (boogwing.cpp:731: htot=442, hact=320, vtot=274, vact=240)
// Pixel clock: 96/14 = 6.857 MHz (integer divider).
wire HBlank, VBlank, HSync, VSync;
wire [7:0] video_r, video_g, video_b;

// V_TOTAL: 269 (57.67Hz native) or 258 (60Hz). Uniform ce_pix /14.
// VERTICAL porches derived from V_TOTAL: FIXED active area (vcnt 8..247,
// 240 lines), VSync right after it with a fixed front porch, the BACK PORCH
// absorbs the V_TOTAL difference -> modeline always valid -> no desync.
wire [9:0] V_TOTAL = mode_60hz ? 10'd258 : 10'd269;
wire [9:0] V_LAST  = V_TOTAL - 10'd1;
reg [9:0] hcnt, vcnt;
always @(posedge clk_sys) begin
	if (video_reset) begin
		hcnt <= 10'd0;
		vcnt <= 10'd0;
	end else if (ce_pix) begin
		if (hcnt == 10'd441) begin
			hcnt <= 10'd0;
			vcnt <= (vcnt == V_LAST) ? 10'd0 : vcnt + 10'd1;
		end else hcnt <= hcnt + 10'd1;
	end
end
assign render_x = hcnt;
assign render_y = vcnt[8:0] + 9'd1;   // whole image moved up by 1px
assign HBlank = ~(hcnt < 10'd320);
assign VBlank = ~((vcnt >= 10'd8) && (vcnt < 10'd248));
assign HSync  = (hcnt >= 10'd340) && (hcnt < 10'd372);
// VSync: 2 lines AFTER the end of the active area (vcnt 248), front porch = 2 lines,
// 3 lines long. FIXED position relative to the end of active (250..252); the back
// porch (253..V_LAST) absorbs the V_TOTAL difference -> always >= 5 lines at
// V_TOTAL 258, valid.
assign VSync  = (vcnt >= 10'd250) && (vcnt < 10'd253);

// RGB output: wired directly from boogwings_top.rgb_out (game_rgb is declared above the instance)
assign video_r = game_rgb[23:16];
assign video_g = game_rgb[15:8];
assign video_b = game_rgb[7:0];

// av_* = composited video (after pause_overlay). Final VGA_R/G/B below.
wire [7:0] av_r, av_g, av_b;

assign CLK_VIDEO = clk_sys;
// Native CE_PIXEL: on MiSTer the CRT adjustment is done in sys_top.

// ── CRT Adjust (Analog H-Size + H-Position + V-Shift + V-Size) ───────────────
// On MiSTer the modules (crt_adjust_sys, crt_vsize) live in sys_top between
// scanlines and vga_osd: here there is only the OSD decode and the true VBlank.
// Analog VGA only, HDMI unchanged. Raster 442x269/258, ce_pix 96/14; the status
// bits are free ones in BoogieWings. On the Pocket core_top leaves CRT_* unconnected.

// ON/OFF (status[72]): OFF = pure native bypass, ON = module active.
// With the scandoubler or the scaler active the CE doubles and the base of the
// read generator is no longer valid -> garbage. Forced off.
reg crt_on;
always @(posedge clk_sys) if (ce_pix)
	crt_on <= status[72] & ~forced_scandoubler;   // Scale (status[21:19]) is HDMI integer scaling only: it does not affect the analog output

// Bidirectional H-Size (status[108:104], two's complement 5-bit -16..+15).
reg signed [4:0] hsize_s;
always @(posedge clk_sys) if (ce_pix) hsize_s <= $signed(status[108:104]);

// H-Position (status[115:109], 7 bit): 0..48 = +0..+48 (right), the rest = negative.
reg [6:0] hpos_d;
always @(posedge clk_sys) if (ce_pix) hpos_d <= status[115:109];
// The menu stores the INDEX in the list: 97 entries (0, +1..+48, -48..-1). The
// wrap must use the LIST LENGTH: with -128 the "-1" entry would be -32 px and
// going from 0 to -1 would make the image JUMP by 32 pixels.
wire signed [8:0] hpos_off = (hpos_d <= 7'd48)
	? $signed({2'b0, hpos_d})
	: $signed({2'b0, hpos_d}) - 9'sd97;

// V-Shift (status[6:1], signed 6-bit -32..+31 lines).
// The full range is needed because the V-Size shrink pulls in the top edge
// (the image is anchored at the bottom) and re-centring is done by hand.
reg signed [5:0] vshift_off;
always @(posedge clk_sys) if (ce_pix) vshift_off <= $signed(status[6:1]);

// Pause overlay: dim + logo + supporter text during pause.
// Clean Pause (status[35]): when ON, the overlay is bypassed (raw passthrough).
// The module gates internally: overlay_on = pause & ~clean.
pause_overlay u_pause_ovl (
	.clk       (clk_sys),
	.pause     (paused_safe),
	.clean     (clean_pause),
	.vblank    (VBlank),
	.render_x  (render_x),
	.render_y  (render_y),
	.rgb_r_in  (video_r),
	.rgb_g_in  (video_g),
	.rgb_b_in  (video_b),
	.rgb_r_out (av_r),
	.rgb_g_out (av_g),
	.rgb_b_out (av_b)
);

// -- CRT values exported to sys_top (MiSTer) ---------------------------------
// The module uses +N = LOWER image, so the value is negated: "+" in the OSD
// means HIGHER, consistent with H-Size. Two's complement OSD field.
//  PVM (retimer): 1 line per step. Cabinet (optical): 3 lines per step.
//  Clamped to the ring: |vsize| <= RING_LINES/2 - 2 = 14.
wire signed [5:0] vsz_step  = $signed(status[70:66]);
wire signed [7:0] vsz_ext   = {{2{vsz_step[5]}}, vsz_step};
wire signed [7:0] vsz_pvm_r = -vsz_ext;
wire signed [7:0] vsz_cab_r = -(vsz_ext + (vsz_ext <<< 1));
function signed [7:0] vsz_clamp(input signed [7:0] v);
	vsz_clamp = (v >  8'sd14) ?  8'sd14 : (v < -8'sd14) ? -8'sd14 : v;
endfunction
wire signed [5:0] vsz_lines = status[71] ? vsz_clamp(vsz_cab_r) : vsz_clamp(vsz_pvm_r);
reg  signed [5:0] crt_vsize_d;
reg               crt_vsmode_d;
always @(posedge clk_sys) if (ce_pix) begin
	crt_vsize_d  <= crt_on ? vsz_lines : 6'sd0;
	crt_vsmode_d <= status[71];
end

assign CRT_ON     = crt_on;
assign CRT_HSIZE  = hsize_s;
assign CRT_HPOS   = hpos_off;
assign CRT_VSHIFT = vshift_off;
assign CRT_VSIZE  = crt_vsize_d;
assign CRT_VSMODE = crt_vsmode_d;
assign CRT_VBL    = VBlank;        // TRUE native VBlank, never the combined blank

// Native outputs: on MiSTer the adjustment happens downstream in sys_top.
assign VGA_HS   = HSync;
assign VGA_VS   = VSync;
assign VGA_R    = av_r;
assign VGA_G    = av_g;
assign VGA_B    = av_b;
assign CE_PIXEL = ce_pix;

// Aspect ratio: Original BoogieWings = 4:3 (single monitor), Full Screen = 0:0
wire [11:0] arx = (!ar) ? 12'd4 : (ar - 1'd1);
wire [11:0] ary = (!ar) ? 12'd3 : 12'd0;

// Integer scaling (Scale menu: Normal / V-Integer / Narrower HV-Integer)
video_freak video_freak
(
	.CLK_VIDEO(clk_sys),
	.CE_PIXEL(ce_pix),
	.VGA_VS(VSync),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(~(HBlank | VBlank)),
	.ARX(arx),
	.ARY(ary),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE(status[21:19])   // 0=Normal 1=V-Int 2=Narrower 3=Wider 4=HV-Integer
);

assign LED_USER = 1'b0;

endmodule
