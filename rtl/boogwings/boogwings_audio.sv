// SPDX-License-Identifier: GPL-3.0-or-later
//
// boogwings_audio — BoogieWings sound subsystem.
//
// MAME boogwing.cpp:
//   - HuC6280A (audio CPU) @ SOUND_XTAL/4 ≈ 8.055 MHz
//   - YM2151 @ SOUND_XTAL/9 ≈ 3.580 MHz
//   - OKI M6295 #0 @ SOUND_XTAL/32 ≈ 1.007 MHz (PIN7_HIGH)
//   - OKI M6295 #1 @ SOUND_XTAL/16 ≈ 2.014 MHz (PIN7_HIGH)
//
// Memory map H6280 (audio_map boogwing.cpp:547):
//   0x000000-0x00FFFF: ROM (64 KB, audiocpu.bin)
//   0x100000-0x100001: NOP (read/write)
//   0x110000-0x110001: YM2151 r/w
//   0x120000-0x120001: OKI #0 r/w
//   0x130000-0x130001: OKI #1 r/w
//   0x140000:          soundlatch (read only)
//   0x1F0000-0x1F1FFF: RAM (8 KB)
//
// IRQ:
//   IRQ0 = soundlatch_irq_cb (= main CPU writes a new latch)
//   IRQ1 = YM2151 IRQ

module boogwings_audio #(
	parameter integer SS_HUC_RAM_IDX   = 0,
	parameter integer SS_HUC_CPU_IDX   = 0,
	parameter integer SS_OKI0_IDX      = 0,
	parameter integer SS_OKI1_IDX      = 0,
	parameter integer SS_YM_IDX        = 0,
	parameter integer SS_AUDIO_BUS_IDX = 0
) (
	input  wire        clk,             // clk_sys (96 MHz)
	input  wire        reset,
	input  wire        ce_audio,        // ~8 MHz (clk_sys / 12)
	input  wire        ce_ym,           // ~3.58 MHz (YM2151 cen)
	input  wire        ce_ym_p1,        // ~1.79 MHz (jt51 cen_p1)
	input  wire        ce_oki0,         // ~1.0 MHz (OKI #0, PIN7_HIGH)
	input  wire        ce_oki1,         // ~2.0 MHz (OKI #1, PIN7_HIGH)
	// Savestate of the ce counter phases (from Template): SAVE = values in; RESTORE = values out + load pulse.
	// Saving the counter phases makes HuC+chips restart from the SAME phase as at save time (audio in sync).
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
	output wire        ce_cnt_load_wr,   // pulse: reloads the counters in Template
	input  wire        pause,           // paused_safe (frame-aligned): the SINGLE audio gate.
	                                    // Stops HuC (CE_IN), chips (gated ce), soundlatch FIFO -> everything
	                                    // stops and restarts in the SAME cycle. The HuC via CE_IN (divider frozen), not RDY.

	// Soundlatch from the main CPU (via DECO104)
	input  wire [7:0]  soundlatch_data,
	input  wire        soundlatch_irq_pulse,  // pulse: new latch written

	// Audiocpu ROM download (BRAM 64 KB) — 2 bytes/clk (low + high of the ioctl word16)
	input  wire        rom_we_lo,
	input  wire        rom_we_hi,
	input  wire [15:0] rom_waddr_lo,
	input  wire [15:0] rom_waddr_hi,
	input  wire [7:0]  rom_wdata_lo,
	input  wire [7:0]  rom_wdata_hi,

	// DDR3 read port for OKI #0 (32-bit fetch with line+1 prefetch in ddram_4port)
	output wire [27:0] oki0_ddr_addr,
	output wire        oki0_ddr_req,
	input  wire [31:0] oki0_ddr_data,
	input  wire        oki0_ddr_ack,

	// DDR3 read port for OKI #1 (32-bit fetch with line+1 prefetch)
	output wire [27:0] oki1_ddr_addr,
	output wire        oki1_ddr_req,
	input  wire [31:0] oki1_ddr_data,
	input  wire        oki1_ddr_ack,

	// OSD audio sel (4 bit each: 0=Default, 1=Mute, 2=MAME, 3-15 = percentage scale)
	input  wire [3:0]  osd_sel_fm,
	input  wire [3:0]  osd_sel_oki0,
	input  wire [3:0]  osd_sel_oki1,
	input  wire [1:0]  osd_presence,     // treble shelving on the mix: 0 Off, 1 +3, 2 +6, 3 +9 dB

	// Audio output (16-bit signed)
	output wire signed [15:0] audio_l,
	output wire signed [15:0] audio_r,

	// Savestate: HUC6280 RAM (ram_mem 8KB 8-bit). Inline adaptor: during SS (HUC
	// paused) the RAM read/write port is redirected to the SS bus. With SS idle: transparent.
	ssbus_if.slave     ss_huc_ram,
	// Savestate: HUC6280 internal state (auto_ss, HUC_SS_BITS = 298 bit) via auto_save_adaptor.
	ssbus_if.slave     ss_huc_cpu,
	// Savestate: OKI #0/#1 internal state (jt6295, auto_ss 359 bit each).
	ssbus_if.slave     ss_oki0,
	ssbus_if.slave     ss_oki1,
	// Savestate: YM2151 internal state (jt51, auto_ss, YM_SS_BITS = 2820 bit).
	ssbus_if.slave     ss_ym,
	// Savestate: persistent state of the audio wrapper (sndlatch FIFO + YM/OKI ctrl + ce phases, 186 bit).
	ssbus_if.slave     ss_audio_bus
);

// Default = MAME mix balance, measured on the attract sequence: the chip writes
// recorded in MAME are played on the core's chips, and the three gains are fitted
// so that the mix matches the MAME output band by band. The fit only changes the
// ratio between the chips; the overall level is kept.
localparam [7:0] DEF_GAIN_FM   = 8'h03;   // 0.1875
localparam [7:0] DEF_GAIN_OKI0 = 8'h60;   // 6.0
localparam [7:0] DEF_GAIN_OKI1 = 8'h17;   // 1.4375
localparam [7:0] MAME_GAIN_FM   = 8'h05;
localparam [7:0] MAME_GAIN_OKI0 = 8'h09;
localparam [7:0] MAME_GAIN_OKI1 = 8'h02;

// mul12 OSD: 0,2 = placeholder, 1 = mute (handled below), 3+ = percent
function [11:0] osd_mul12_aud;
	input [3:0] sel;
	case (sel)
		4'd3:  osd_mul12_aud = 12'd64;    // 25%
		4'd4:  osd_mul12_aud = 12'd128;   // 50%
		4'd5:  osd_mul12_aud = 12'd192;   // 75%
		4'd6:  osd_mul12_aud = 12'd256;   // 100%
		4'd7:  osd_mul12_aud = 12'd320;   // 125%
		4'd8:  osd_mul12_aud = 12'd384;   // 150%
		4'd9:  osd_mul12_aud = 12'd512;   // 200%
		4'd10: osd_mul12_aud = 12'd640;   // 250%
		4'd11: osd_mul12_aud = 12'd768;   // 300%
		4'd12: osd_mul12_aud = 12'd1024;  // 400%
		4'd13: osd_mul12_aud = 12'd1280;  // 500%
		4'd14: osd_mul12_aud = 12'd1792;  // 700%
		4'd15: osd_mul12_aud = 12'd2560;  // 1000%
		default: osd_mul12_aud = 12'd256;
	endcase
endfunction

function [7:0] gain_resolve;
	input [3:0] sel;
	input [7:0] def_g;
	input [7:0] mame_g;
	reg [19:0] scaled;
	begin
		case (sel)
			4'd0: gain_resolve = def_g;
			4'd1: gain_resolve = 8'h00;
			4'd2: gain_resolve = mame_g;
			default: begin
				scaled = def_g * osd_mul12_aud(sel);
				gain_resolve = (scaled[19:8] > 12'hFF) ? 8'hFF : scaled[15:8];
			end
		endcase
	end
endfunction

wire [7:0] gain_fm   = gain_resolve(osd_sel_fm,   DEF_GAIN_FM,   MAME_GAIN_FM);
wire [7:0] gain_oki0 = gain_resolve(osd_sel_oki0, DEF_GAIN_OKI0, MAME_GAIN_OKI0);
wire [7:0] gain_oki1 = gain_resolve(osd_sel_oki1, DEF_GAIN_OKI1, MAME_GAIN_OKI1);

// =====================================================================
// Audiocpu ROM 64 KB — split into 2 BRAMs (even/odd byte) to write both
// bytes of an ioctl word in the same clk (no serializing FSM).
// rom_even[N] = byte addr 2N (= rom_waddr_lo[15:1])
// rom_odd [N] = byte addr 2N+1 (= rom_waddr_hi[15:1])
// =====================================================================
(* ramstyle = "M10K", no_rw_check *) reg [7:0] rom_even [0:32767];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] rom_odd  [0:32767];
reg [7:0] rom_even_rd, rom_odd_rd;
always @(posedge clk) begin
	if (rom_we_lo) rom_even[rom_waddr_lo[15:1]] <= rom_wdata_lo;
end
always @(posedge clk) begin
	if (rom_we_hi) rom_odd [rom_waddr_hi[15:1]] <= rom_wdata_hi;
end
reg       cpu_addr0_d;

// =====================================================================
// Audiocpu RAM 8 KB (BRAM)
// =====================================================================
(* ramstyle = "M10K", no_rw_check *) reg [7:0] ram_mem [0:8191];
reg [7:0] ram_rd_r;

// =====================================================================
// H6280 bus
// =====================================================================
wire [20:0] cpu_addr;
wire [7:0]  cpu_dout;
wire        cpu_wr_n, cpu_rd_n;
wire        cpu_ce_pulse;          // CE_N (active LOW) → high pulse when the bus is valid
wire [23:0] cpu_aud_l, cpu_aud_r;  // internal PSG (not used by boogwing)
reg  [7:0]  cpu_din;

// Memory decode
wire is_rom = (cpu_addr[20:16] == 5'h00);                 // 0x000000-0x00FFFF
wire is_ym  = (cpu_addr[20:16] == 5'h11);                 // 0x110000
wire is_ok0 = (cpu_addr[20:16] == 5'h12);                 // 0x120000
wire is_ok1 = (cpu_addr[20:16] == 5'h13);                 // 0x130000
wire is_snd = (cpu_addr[20:16] == 5'h14);                 // 0x140000
wire is_ram = (cpu_addr[20:13] == 8'b1111_1000);          // 0x1F0000-0x1F1FFF (= [20:13]=0xF8)

// BRAM read pipeline (1 clk latency)
// ROM: addr bit 0 selects even/odd. Indexing uses addr[15:1].
always @(posedge clk) rom_even_rd <= rom_even[cpu_addr[15:1]];
always @(posedge clk) rom_odd_rd  <= rom_odd [cpu_addr[15:1]];
always @(posedge clk) cpu_addr0_d <= cpu_addr[0];
wire [7:0] rom_rd_r = cpu_addr0_d ? rom_odd_rd : rom_even_rd;

// WAIT_N=1 always. jt51_mmr samples `write=!cs_n && !wr_n` directly at
// posedge clk (NOT gated by cen_p1) for the MMR registers: reg_sel <= din happens
// at every clk with write=1. So 1 clk of wr_n=0 is enough.
wire wait_n = 1'b1;

// Savestate: during SS (HUC paused) RAM read/write are redirected to the SS bus. With SS idle:
// transparent (addr=cpu_addr, write=is_ram&~cpu_wr_n, data=cpu_dout).
wire        ss_huc_sel  = ss_huc_ram.access(SS_HUC_RAM_IDX);
wire [12:0] ram_addr    = ss_huc_sel ? ss_huc_ram.addr[12:0] : cpu_addr[12:0];
// ram_we gated by ~pause: if the pause falls in the middle of a RAM write, WR_N stays frozen
// low -> without the gate the stale write REWRITES, every clk, the RAM just restored from the
// HUC_RAM chunk (which precedes the HUC_CPU chunk that realigns the strobes) = 1 corrupted byte.
// In a user pause it only suppresses idempotent rewrites (same data). With pause=0 no effect.
wire        ram_we      = ss_huc_sel ? ss_huc_ram.write      : (is_ram & ~cpu_wr_n & ~pause);
wire [7:0]  ram_wdata   = ss_huc_sel ? ss_huc_ram.data[7:0]  : cpu_dout;

always @(posedge clk) ram_rd_r <= ram_mem[ram_addr];

// RAM write — level: cpu_wr_n=0 for ~4 clk, but the write is idempotent (same data
// written N times = written once).
always @(posedge clk) begin
	if (ram_we) ram_mem[ram_addr] <= ram_wdata;
end

// SS setup + read_response (read_delay 1 clk = BRAM latency of ram_rd_r).
reg ss_huc_rd_d;
always @(posedge clk) begin
	ss_huc_ram.setup(SS_HUC_RAM_IDX, 8192, 0);  // 8192 bytes, width 0 = 8 bit
	ss_huc_rd_d <= ss_huc_sel & ss_huc_ram.read;
	if (ss_huc_sel & ss_huc_ram.write) ss_huc_ram.write_ack(SS_HUC_RAM_IDX);
	if (ss_huc_rd_d) ss_huc_ram.read_response(SS_HUC_RAM_IDX, {56'b0, ram_rd_r});
end

// Soundlatch FIFO 16-deep — with the +2% refresh the 68K sends the audio commands
// closer together, while the H6280 (fixed clock) handles them in IRQ1: two writes
// before the read would clobber a command = audio hiccup. The FIFO queues every
// command and delivers them all. 5-bit pointers (1 wrap bit) -> FULL and EMPTY
// distinct (no aliasing). Push gated on !full. Edge-detect on the pulse (a level as
// wide as a 68K bus cycle) and on the H6280 read (RD_N low for 6-24 clk).
reg  [7:0] sndlatch_fifo [0:15];
reg  [4:0] sl_wptr, sl_rptr;       // 5 bit: [4]=wrap, [3:0]=index
reg        sl_pulse_d, sl_rd_d;
wire       sl_rd_lvl = is_snd && ~cpu_rd_n;
wire       sl_empty  = (sl_wptr == sl_rptr);
wire       sl_full   = (sl_wptr[4] != sl_rptr[4]) && (sl_wptr[3:0] == sl_rptr[3:0]);
// soundlatch_irq_pulse NOT gated: during the SS the 68k (mini-handler) does NOT write the soundlatch
// (stack only), so gating the push would lose a command. Edge-detect on the direct pulse.
// sl_pulse_d/sl_rd_d are saved in the SS -> no spurious edge at restore. Transparent with SS off.
wire       sl_push   = (soundlatch_irq_pulse & ~sl_pulse_d) & ~sl_full;   // rising-edge, no overflow
wire       sl_pop    = (~sl_rd_lvl & sl_rd_d) & ~sl_empty;                // falling-edge read

integer sl_i;
always @(posedge clk) begin
	sl_pulse_d <= soundlatch_irq_pulse;   // edge-detect on the direct pulse (no command lost at SS)
	sl_rd_d    <= sl_rd_lvl;
	if (reset) begin
		sl_wptr <= 5'd0;
		sl_rptr <= 5'd0;
	end else if (audio_bus_ss_wr) begin
		// RESTORE savestate (priority): loads FIFO + pointers + edge-detect. Same order as the
		// save (fifo[i] from bits [8*i+:8]). Game paused -> push/pop disabled in this cycle.
		// sl_pulse_d/sl_rd_d restored CONSISTENTLY (they win over the assignments at the top of this
		// same always) -> no artificial edge on soundlatch_irq at restore -> no spurious push.
		for (sl_i = 0; sl_i < 16; sl_i = sl_i + 1)
			sndlatch_fifo[sl_i] <= ab_fifo_flat_load[8*sl_i +: 8];
		sl_wptr    <= ab_sl_wptr_load;
		sl_rptr    <= ab_sl_rptr_load;
		sl_pulse_d <= ab_sl_pulse_d_load;
		// sl_rd_d: NOT from the save but from the LIVE level. The saved value belongs to the saved
		// machine, but sl_rd_lvl here reflects the strobes of the current session (already realigned
		// to the restored state by chunk 20 (HUC_CPU), which precedes this one): loading the saved
		// value would create a false falling edge = spurious pop (audio command lost). d==lvl -> no
		// edge by construction; the following edges are the real ones of the resumed CPU.
		sl_rd_d    <= sl_rd_lvl;
	end else begin
		if (sl_push) begin
			sndlatch_fifo[sl_wptr[3:0]] <= soundlatch_data;
			sl_wptr <= sl_wptr + 5'd1;
		end
		if (sl_pop) sl_rptr <= sl_rptr + 5'd1;
	end
end

wire [7:0] sndlatch_reg = sndlatch_fifo[sl_rptr[3:0]];   // queue head read by the H6280
wire irq1_n = sl_empty;   // IRQ1 asserted (=0) while there are commands in the queue

// =====================================================================
// YM2151 (jt51) — addr 0x110000, controlled by the H6280
// =====================================================================
// jt51_mmr.v line 162: `if(write) reg_sel <= din` is in @(posedge clk) WITHOUT
// cen_p1 gating. So wr_n=0 for 1 clk is enough.
// FM pitch: the YM write must be ONE SINGLE clk pulse with STABLE addr/data,
// not a wide level. The HuC6280 keeps wr_n low for ~12 clk and jt51_mmr samples every
// posedge WITHOUT edge-detect: on the a0 0->1 transition (addr->data) a transient sample
// corrupts reg_kc/reg_kf of a channel -> out of tune until reload. The write is qualified
// with cpu_ce_pulse (= bus valid, 1 clk, addr/dout guaranteed stable) -> 1 single clean write.
wire        ym_cs_n  = ~is_ym;
wire        ym_wr_n  = ~(is_ym & ~cpu_wr_n & cpu_ce_pulse);  // 1-clk pulse on a valid bus
wire        ym_a0    = cpu_addr[0];
wire [7:0]  ym_din   = cpu_dout;
wire [7:0]  ym_dout_raw;
wire        ym_irq_n;

// FM pitch: the jt51 busy flag is effectively dead (set only on cen=1, but the write
// lasts 1 clk -> they coincide ~2% of the time). The H6280 driver reads busy=0 and writes
// notes back to back: the 2nd write clears the pending KC/KF update of the 1st (jt51_mmr
// up_* clear) -> a channel stays out of tune until reload. The real chip has a ~80us busy
// that holds the CPU back between writes. Back-pressure: a local timer armed on every YM
// data write (a0=1), ORed into bit7 (busy) of the dout read by the H6280 -> the polling
// driver waits.
localparam [12:0] YM_BUSY_TICKS = 13'd7680;  // ~80us @ 96MHz (80e-6*96e6)
reg [12:0] ym_busy_cnt;
wire ym_data_wr = is_ym & cpu_addr[0] & ~cpu_wr_n & cpu_ce_pulse;  // write to the data reg (a0=1)
always @(posedge clk) begin
	if (reset)               ym_busy_cnt <= 13'd0;
	else if (audio_bus_ss_wr) ym_busy_cnt <= ab_ym_busy_cnt_load;   // restore (priority)
	else if (ym_data_wr)     ym_busy_cnt <= YM_BUSY_TICKS;          // arm busy on a data write
	// decrement gated by ~pause: the busy models CHIP time (jt51 frozen in pause) -> counting
	// down at 96MHz in pause it would expire early (FM write too close at resume) and would be
	// captured already expired at save. With pause=0 no effect.
	else if (ym_busy_cnt != 13'd0 && !pause) ym_busy_cnt <= ym_busy_cnt - 13'd1;
end
wire ym_busy_local = (ym_busy_cnt != 13'd0);
// dout read by the H6280: bit7 = real jt51 busy OR local busy (back-pressure).
wire [7:0]  ym_dout = {ym_dout_raw[7] | ym_busy_local, ym_dout_raw[6:0]};
wire signed [15:0] ym_left, ym_right;

jt51 u_ym (
	.rst    (reset),
	.clk    (clk),
	.cen    (ce_ym),
	.cen_p1 (ce_ym_p1),
	.cs_n   (ym_cs_n),
	.wr_n   (ym_wr_n),
	.a0     (ym_a0),
	.din    (ym_din),
	.dout   (ym_dout_raw),
	.ct1    (),
	.ct2    (),
	.irq_n  (ym_irq_n),
	.sample (),
	.left   (),
	.right  (),
	.xleft  (ym_left),   // xleft/xright (full-res continuous)
	.xright (ym_right),  // instead of left/right (low-res, latched at the sample strobe)
	.auto_ss_in (ym_ss_in),
	.auto_ss_out(ym_ss_out),
	.auto_ss_wr (ym_ss_wr)
);

// =====================================================================
// OKI bank switch: MAME port_write_handler receives {CT2, CT1} (= bits 7:6 of the
// data written to YM2151 register 0x1B). MAME boogwing.cpp:694-695:
//   oki[1].bank = (data & 2) >> 1 = CT2 bit
//   oki[0].bank = data & 1 = CT1 bit
// So data[7:6] = {CT2,CT1} is taken and mapped to the banks.
// =====================================================================
reg [7:0] ym_last_reg;
always @(posedge clk) begin
	if (audio_bus_ss_wr)                                     // restore (priority)
		ym_last_reg <= ab_ym_last_reg_load;
	else if (is_ym && ~cpu_addr[0] && ~cpu_wr_n && cpu_ce_pulse)  // 1 clk, stable bus
		ym_last_reg <= cpu_dout;
end
reg [1:0] oki_bank_bits;        // {CT2, CT1}
always @(posedge clk) begin
	if (reset) oki_bank_bits <= 2'd0;
	else if (audio_bus_ss_wr) oki_bank_bits <= ab_oki_bank_load;   // restore (priority)
	else if (is_ym && cpu_addr[0] && ~cpu_wr_n && cpu_ce_pulse && ym_last_reg == 8'h1B)
		oki_bank_bits <= cpu_dout[7:6];   // {CT2, CT1}
end
wire oki0_bank = oki_bank_bits[0];   // CT1 → OKI #0 bank
wire oki1_bank = oki_bank_bits[1];   // CT2 → OKI #1 bank

// =====================================================================
// OKI #0 (jt6295) — 1.0 MHz, PIN7_HIGH (ss=1), DDR3 ROM 512 KB
// =====================================================================
wire        oki0_wrn = ~(is_ok0 & ~cpu_wr_n);
wire [7:0]  oki0_dout;
wire signed [13:0] oki0_sound;
wire [17:0] oki0_rom_addr;
wire        oki0_rom_ok_w;
// cen=ce_oki0 raw (no gating with rom_ok): jt6295_ctrl handles the wait on
// rom_ok internally. Gating the 1-clk pulse with rom_ok loses samples (= silence).
jt6295 #(.INTERPOL(1)) u_oki0 (
	.rst        (reset),
	.clk        (clk),
	.cen        (ce_oki0),
	.ss         (1'b1),
	.wrn        (oki0_wrn),
	.din        (cpu_dout),
	.dout       (oki0_dout),
	.rom_addr   (oki0_rom_addr),
	.rom_data   (oki0_rom_data),
	.rom_ok     (oki0_rom_ok_w),
	.sound      (oki0_sound),
	.sample     (),
	.auto_ss_in (oki0_ss_in),
	.auto_ss_out(oki0_ss_out),
	.auto_ss_wr (oki0_ss_wr)
);

// =====================================================================
// OKI #1 (jt6295) — 2.0 MHz, PIN7_HIGH (ss=1), DDR3 ROM 512 KB
// =====================================================================
wire        oki1_wrn = ~(is_ok1 & ~cpu_wr_n);
wire [7:0]  oki1_dout;
wire signed [13:0] oki1_sound;
wire [17:0] oki1_rom_addr;
wire        oki1_rom_ok_w;

jt6295 #(.INTERPOL(1)) u_oki1 (
	.rst        (reset),
	.clk        (clk),
	.cen        (ce_oki1),
	.ss         (1'b1),
	.wrn        (oki1_wrn),
	.din        (cpu_dout),
	.dout       (oki1_dout),
	.rom_addr   (oki1_rom_addr),
	.rom_data   (oki1_rom_data),
	.rom_ok     (oki1_rom_ok_w),
	.sound      (oki1_sound),
	.sample     (),
	.auto_ss_in (oki1_ss_in),
	.auto_ss_out(oki1_ss_out),
	.auto_ss_wr (oki1_ss_wr)
);

// =====================================================================
// OKI DDR3 bridge — 32-bit DDR3 port with 8-byte cache + line+1 prefetch inside
// ddram_4port. jt6295 changes rom_addr every ~3 clk (cen32); DDR3 cache hit = 1 clk,
// miss = 20 clk. This bridge:
//  - emits a byte addr; ddram_4port aggregates 4 bytes (cache_addr[27:3] match in
//    an 8-byte line = 2 32-bit words). Cache hit = ack in 1 clk.
//  - latches the 32-bit word in `oki0_word` as soon as the ack arrives, even if
//    the addr has changed in the meantime; the byte is selected by addr[1:0].
//  - keeps rom_ok at 1 while the requested addr stays inside the same latched
//    32-bit word (= same addr[17:2]) → 0 round-trips → byte extracted directly
//    from the word. When it leaves the word → 1 round-trip (cache hit 1 clk if
//    inside the 8-byte line, miss otherwise).
// MAME oki bank: 0x40000 (256 KB) window inside a 512 KB ROM.
// =====================================================================
// PREFETCH BUFFER (relieves the DDR pressure on audio without adding load):
// besides the CURRENT word (oki0_word), the NEXT word is kept already preloaded
// (oki0_word_n). When jt6295 moves on to the next word, it is ALREADY there -> rom_ok=1
// without waiting for the DDR (which may be busy with tiles/sprites). The prefetch
// of the "next" word starts ONLY when the current one is valid and no fetch is pending:
// 1 request at a time, the SAME number of DDR accesses as without prefetch but EARLIER
// -> it does NOT steal bandwidth from sprites/tiles, it only decouples the LATENCY.
reg [17:0] oki0_addr_pending;    // addr requested from the DDR (fetch in progress)
reg [15:0] oki0_word_addr;       // addr[17:2] of the CURRENT word (16'hFFFF=invalid)
reg [15:0] oki0_word_n_addr;     // addr[17:2] of the NEXT word (prefetch)
reg [31:0] oki0_word;            // current 32-bit word
reg [31:0] oki0_word_n;          // next 32-bit word (prefetch)
reg        oki0_req_toggle;
reg        oki0_fetch_busy;
reg        oki0_fetch_is_next;   // 1 = the fetch in progress is for the NEXT word, 0 = for the current one
reg        oki0_rom_ok;
wire       oki0_ddr_ack_match = (oki0_ddr_ack == oki0_req_toggle);
wire [15:0] oki0_cur_widx  = oki0_rom_addr[17:2];
wire [15:0] oki0_next_widx = oki0_rom_addr[17:2] + 16'd1;
wire       oki0_word_hit   = (oki0_word_addr   == oki0_cur_widx);
wire       oki0_word_n_hit = (oki0_word_n_addr == oki0_cur_widx);  // jt6295 has moved on to next

always @(posedge clk) begin
	if (reset) begin
		oki0_addr_pending <= 18'h00000;
		oki0_word_addr    <= 16'hFFFF;        // invalid
		oki0_word_n_addr  <= 16'hFFFF;
		oki0_word         <= 32'd0;
		oki0_word_n       <= 32'd0;
		oki0_req_toggle   <= 1'b0;
		oki0_fetch_busy   <= 1'b0;
		oki0_fetch_is_next<= 1'b0;
		oki0_rom_ok       <= 1'b0;
	end else begin
		// 1) Fetch ack: latch into the current or the next word depending on the type.
		//    In pause/SS the in-flight req is CLOSED anyway (fetch_busy drops -> quiescence,
		//    no deadlock) but the DATA is discarded (tags not written): it would belong to the
		//    pre-restore bank. At resume: clean miss -> refetch with the final bank.
		if (oki0_fetch_busy && oki0_ddr_ack_match) begin
			if (!pause) begin
				if (oki0_fetch_is_next) begin
					oki0_word_n      <= oki0_ddr_data;
					oki0_word_n_addr <= oki0_addr_pending[17:2];
				end else begin
					oki0_word        <= oki0_ddr_data;
					oki0_word_addr   <= oki0_addr_pending[17:2];
				end
			end
			oki0_fetch_busy <= 1'b0;
		end

		// 2) jt6295 has moved on to the NEXT word (already preloaded): promote next->current
		//    (shift) without a DDR round-trip. Happens when current is no longer a hit but next is.
		// SS: promotion and scheduler (below) gated with !pause (paused_safe): in pause/SS the
		// bridge does NOT launch new reqs nor shuffle its state (the jt6295 restore changes rom_addr
		// under ss_hold: a req launched there would stay PENDING for the whole SS window,
		// ddram_ss_idle=0). The ack branch (1) stays ALWAYS
		// live: the in-flight req closes and ss_idle can rise. With pause=0 the gating has no effect.
		if (!pause && !oki0_fetch_busy && !oki0_word_hit && oki0_word_n_hit) begin
			oki0_word      <= oki0_word_n;
			oki0_word_addr <= oki0_word_n_addr;
			oki0_word_n_addr <= 16'hFFFF;   // next must now be prefetched again
		end

		// 3) rom_ok: the current word is ready (hit) or the next one is (it will be promoted)
		oki0_rom_ok <= (oki0_word_hit || oki0_word_n_hit) && !oki0_fetch_busy;

		// 4) Fetch scheduler (1 request at a time, priority to the CURRENT word):
		if (!pause && !oki0_fetch_busy) begin
			if (!oki0_word_hit && !oki0_word_n_hit) begin
				// total miss: fetch the current word AT ONCE
				oki0_addr_pending  <= oki0_rom_addr;
				oki0_fetch_is_next <= 1'b0;
				oki0_req_toggle    <= ~oki0_req_toggle;
				oki0_fetch_busy    <= 1'b1;
			end else if (oki0_word_hit && (oki0_word_n_addr != oki0_next_widx)) begin
				// current ready but next missing: PREFETCH the next word (early, 1 request)
				oki0_addr_pending  <= {oki0_next_widx[15:0], 2'b00};
				oki0_fetch_is_next <= 1'b1;
				oki0_req_toggle    <= ~oki0_req_toggle;
				oki0_fetch_busy    <= 1'b1;
			end
		end

		// Restore: invalidate the cache tags at the CHIP load (OKI0 chunk, which PRECEDES the
		// AUDIO_BUS chunk with the bank): the tag is only addr[17:2] WITHOUT the bank, and the
		// jt6295 ctrl FSM runs at full clk even in pause — with stale tags it would see rom_ok=1
		// and consume rom_data of the old bank/session right after its own load.
		// Invalid tags -> rom_ok=0 -> FSM stopped until resume. Pulse only at restore.
		if (oki0_ss_wr) begin
			oki0_word_addr   <= 16'hFFFF;
			oki0_word_n_addr <= 16'hFFFF;
			oki0_rom_ok      <= 1'b0;   // the rom_ok register would evaluate the PRE-invalidation tags
		end
	end
end
// Byte extract: from the current word if hit, otherwise from the next (just before the promotion)
wire [31:0] oki0_word_sel = oki0_word_hit ? oki0_word : oki0_word_n;
wire [7:0] oki0_rom_data = oki0_word_sel[{oki0_rom_addr[1:0], 3'b000} +:8];
assign oki0_ddr_addr = 28'h5500000 + {9'd0, oki0_bank, oki0_addr_pending};
assign oki0_ddr_req  = oki0_req_toggle;
assign oki0_rom_ok_w = oki0_rom_ok;

// OKI1 PREFETCH BUFFER (same as OKI0: current + preloaded next, decouples the DDR
// latency without adding load -> robust audio, sprites/tiles unaffected).
reg [17:0] oki1_addr_pending;
reg [15:0] oki1_word_addr;
reg [15:0] oki1_word_n_addr;
reg [31:0] oki1_word;
reg [31:0] oki1_word_n;
reg        oki1_req_toggle;
reg        oki1_fetch_busy;
reg        oki1_fetch_is_next;
reg        oki1_rom_ok;
wire       oki1_ddr_ack_match = (oki1_ddr_ack == oki1_req_toggle);
wire [15:0] oki1_cur_widx  = oki1_rom_addr[17:2];
wire [15:0] oki1_next_widx = oki1_rom_addr[17:2] + 16'd1;
wire       oki1_word_hit   = (oki1_word_addr   == oki1_cur_widx);
wire       oki1_word_n_hit = (oki1_word_n_addr == oki1_cur_widx);

always @(posedge clk) begin
	if (reset) begin
		oki1_addr_pending <= 18'h00000;
		oki1_word_addr    <= 16'hFFFF;
		oki1_word_n_addr  <= 16'hFFFF;
		oki1_word         <= 32'd0;
		oki1_word_n       <= 32'd0;
		oki1_req_toggle   <= 1'b0;
		oki1_fetch_busy   <= 1'b0;
		oki1_fetch_is_next<= 1'b0;
		oki1_rom_ok       <= 1'b0;
	end else begin
		// Ack: always closes, data discarded in pause (as OKI0)
		if (oki1_fetch_busy && oki1_ddr_ack_match) begin
			if (!pause) begin
				if (oki1_fetch_is_next) begin
					oki1_word_n      <= oki1_ddr_data;
					oki1_word_n_addr <= oki1_addr_pending[17:2];
				end else begin
					oki1_word        <= oki1_ddr_data;
					oki1_word_addr   <= oki1_addr_pending[17:2];
				end
			end
			oki1_fetch_busy <= 1'b0;
		end

		// SS: promotion+scheduler gated with !pause, ack branch always live (as OKI0)
		if (!pause && !oki1_fetch_busy && !oki1_word_hit && oki1_word_n_hit) begin
			oki1_word        <= oki1_word_n;
			oki1_word_addr   <= oki1_word_n_addr;
			oki1_word_n_addr <= 16'hFFFF;
		end

		oki1_rom_ok <= (oki1_word_hit || oki1_word_n_hit) && !oki1_fetch_busy;

		if (!pause && !oki1_fetch_busy) begin
			if (!oki1_word_hit && !oki1_word_n_hit) begin
				oki1_addr_pending  <= oki1_rom_addr;
				oki1_fetch_is_next <= 1'b0;
				oki1_req_toggle    <= ~oki1_req_toggle;
				oki1_fetch_busy    <= 1'b1;
			end else if (oki1_word_hit && (oki1_word_n_addr != oki1_next_widx)) begin
				oki1_addr_pending  <= {oki1_next_widx[15:0], 2'b00};
				oki1_fetch_is_next <= 1'b1;
				oki1_req_toggle    <= ~oki1_req_toggle;
				oki1_fetch_busy    <= 1'b1;
			end
		end

		// Restore: invalidate the cache tags at the chip load (as OKI0)
		if (oki1_ss_wr) begin
			oki1_word_addr   <= 16'hFFFF;
			oki1_word_n_addr <= 16'hFFFF;
			oki1_rom_ok      <= 1'b0;   // as OKI0
		end
	end
end
wire [31:0] oki1_word_sel = oki1_word_hit ? oki1_word : oki1_word_n;
wire [7:0] oki1_rom_data = oki1_word_sel[{oki1_rom_addr[1:0], 3'b000} +:8];
assign oki1_ddr_addr = 28'h5580000 + {9'd0, oki1_bank, oki1_addr_pending};
assign oki1_ddr_req  = oki1_req_toggle;
assign oki1_rom_ok_w = oki1_rom_ok;

// CPU din mux — priority if-else (safer than case(1'b1))
always @(*) begin
	if      (is_rom) cpu_din = rom_rd_r;
	else if (is_ram) cpu_din = ram_rd_r;
	else if (is_snd) cpu_din = sndlatch_reg;
	else if (is_ym ) cpu_din = ym_dout;
	else if (is_ok0) cpu_din = oki0_dout;
	else if (is_ok1) cpu_din = oki1_dout;
	else             cpu_din = 8'hFF;
end

// =====================================================================
// Savestate of the HUC6280 internal state (auto_ss) via auto_save_adaptor.
// With SS idle huc_ss_wr=0 -> the chip is transparent. During restore huc_ss_wr pulses (CPU stopped
// in paused_safe) -> the chip reloads its registers from huc_ss_in.
// =====================================================================
localparam integer HUC_SS_BITS = 298;   // 252 core+AG+CS+SavedC+MI(42) + top state(38) + CPU_CLK_CNT(5) + IO_CLK_CNT(3)
wire [HUC_SS_BITS-1:0] huc_ss_out, huc_ss_in;
wire                   huc_ss_wr;
auto_save_adaptor #(.N_BITS(HUC_SS_BITS), .SS_IDX(SS_HUC_CPU_IDX)) u_huc_ss_adaptor (
	.clk     (clk),
	.ssbus   (ss_huc_cpu),
	.bits_in (huc_ss_out),
	.bits_out(huc_ss_in),
	.bits_wr (huc_ss_wr)
);

// OKI #0/#1 (jt6295) internal state — auto_ss 359 bit each.
localparam integer OKI_SS_BITS = 359;
wire [OKI_SS_BITS-1:0] oki0_ss_out, oki0_ss_in, oki1_ss_out, oki1_ss_in;
wire                   oki0_ss_wr, oki1_ss_wr;
auto_save_adaptor #(.N_BITS(OKI_SS_BITS), .SS_IDX(SS_OKI0_IDX)) u_oki0_ss_adaptor (
	.clk(clk), .ssbus(ss_oki0),
	.bits_in(oki0_ss_out), .bits_out(oki0_ss_in), .bits_wr(oki0_ss_wr)
);
auto_save_adaptor #(.N_BITS(OKI_SS_BITS), .SS_IDX(SS_OKI1_IDX)) u_oki1_ss_adaptor (
	.clk(clk), .ssbus(ss_oki1),
	.bits_in(oki1_ss_out), .bits_out(oki1_ss_in), .bits_wr(oki1_ss_wr)
);

// YM2151 (jt51) internal state — auto_ss.
localparam integer YM_SS_BITS = 2820;   // 2780 + write-staging(40) = up_*/op_din/reg_sel in flight
wire [YM_SS_BITS-1:0] ym_ss_out, ym_ss_in;
wire                  ym_ss_wr;
// POCKET: a single buffer instead of two (2820 fewer registers). Equivalent: the
// jt51 reads auto_ss_in only while auto_ss_wr is asserted.
auto_save_adaptor_1buf #(.N_BITS(YM_SS_BITS), .SS_IDX(SS_YM_IDX)) u_ym_ss_adaptor (
	.clk(clk), .ssbus(ss_ym),
	.bits_in(ym_ss_out), .bits_out(ym_ss_in), .bits_wr(ym_ss_wr)
);

// Audio bus wrapper state — 186 bits of PERSISTENT state not internal to the chips.
//   [160:0] (161 bits): sndlatch FIFO 16x8 (128) + sl_wptr[4:0]+sl_rptr[4:0] (10) + ym_busy_cnt[12:0] (13)
//   + ym_last_reg[7:0] (8) + oki_bank_bits[1:0] (2). Without it, at restore the queued audio
//   commands disappear and the YM bank/busy are lost -> mute/glitchy audio.
// 186 bits: 163 base (FIFO+ctrl+edge) + 23 of ce counter phases ([185:163]).
//   [185:180] ce_oki1_cnt(6)  [179:173] ce_oki0_cnt(7)  [172] ce_ym_toggle  [171:167] ce_ym_cnt(5)
//   [166:163] ce_audio_cnt(4)  [162] sl_rd_d  [161] sl_pulse_d  [160:0] base (see below)
localparam integer AUDIO_BUS_SS_BITS = 186;
wire [AUDIO_BUS_SS_BITS-1:0] audio_bus_ss_out, audio_bus_ss_in;
wire                         audio_bus_ss_wr;
auto_save_adaptor #(.N_BITS(AUDIO_BUS_SS_BITS), .SS_IDX(SS_AUDIO_BUS_IDX)) u_audio_bus_ss_adaptor (
	.clk(clk), .ssbus(ss_audio_bus),
	.bits_in(audio_bus_ss_out), .bits_out(audio_bus_ss_in), .bits_wr(audio_bus_ss_wr)
);
// SAVE: FIFO (fifo[i] in [8*i+7:8*i]) + registers + ce counter phases (from the _in ports, from Template).
wire [127:0] fifo_flat;
genvar gi;
generate for (gi = 0; gi < 16; gi = gi + 1) begin : g_fifo_flat
	assign fifo_flat[8*gi +: 8] = sndlatch_fifo[gi];
end endgenerate
assign audio_bus_ss_out = {ce_oki1_cnt_in, ce_oki0_cnt_in, ce_ym_toggle_in, ce_ym_cnt_in, ce_audio_cnt_in,
                           sl_rd_d, sl_pulse_d, oki_bank_bits, ym_last_reg, ym_busy_cnt, sl_rptr, sl_wptr, fifo_flat};
// RESTORE: unpack in the SAME order (endianness identical to the save).
wire [1:0]   ab_oki_bank_load    = audio_bus_ss_in[160:159];
wire [7:0]   ab_ym_last_reg_load = audio_bus_ss_in[158:151];
wire [12:0]  ab_ym_busy_cnt_load = audio_bus_ss_in[150:138];
wire [4:0]   ab_sl_rptr_load     = audio_bus_ss_in[137:133];
wire [4:0]   ab_sl_wptr_load     = audio_bus_ss_in[132:128];
wire [127:0] ab_fifo_flat_load   = audio_bus_ss_in[127:0];
wire         ab_sl_pulse_d_load  = audio_bus_ss_in[161];
// RESTORE of the ce counter phases -> outputs to Template (loaded when ce_cnt_load_wr pulses).
assign ce_audio_cnt_load  = audio_bus_ss_in[166:163];
assign ce_ym_cnt_load     = audio_bus_ss_in[171:167];
assign ce_ym_toggle_load  = audio_bus_ss_in[172];
assign ce_oki0_cnt_load   = audio_bus_ss_in[179:173];
assign ce_oki1_cnt_load   = audio_bus_ss_in[185:180];
assign ce_cnt_load_wr     = audio_bus_ss_wr;   // restore pulse -> Template reloads the counters

// =====================================================================
// H6280 instance
// =====================================================================
// The CPU clock enable is generated inside the module (internal divider); the
// ce_audio input is not used here: CE_IN only freezes the divider during pause.
HUC6280 u_cpu (
	.CLK    (clk),
	.CE_IN  (~pause),       // in normal play (pause=0) CE_IN=1 -> the divider runs at full
	                        // clk (96/24=4MHz, identical to the original). In pause/SS (pause=paused_safe=1)
	                        // CE_IN=0 -> divider FROZEN (CPU_CLK_CNT stopped) -> the HuC does not drift in
	                        // phase: at restore it restarts IN PHASE. Keeps long notes right (no off-phase key-off).
	.RST_N  (~reset),
	.WAIT_N (wait_n),       // always 1 (see wait_n)
	.RDY    (1'b1),         // RDY is not used for the pause (CE_IN does it). Neutral on BoogieWings:
	                        // the HuC does not access VDC/VCE (0xFF0000+), the video wait state never triggers.
	.DI     (cpu_din),
	.NMI_N  (1'b1),
	.IRQ1_N (irq1_n),       // soundlatch IRQ (MAME IRQ0 → H6280 IRQ1)
	.IRQ2_N (ym_irq_n),     // YM2151 timer IRQ → H6280 IRQ2 (MAME IRQ2)
	.K      (8'h00),
	.VDCNUM (1'b0),
	.SX     (),
	.A      (cpu_addr),
	.DO     (cpu_dout),
	.WR_N   (cpu_wr_n),
	.RD_N   (cpu_rd_n),
	.CE     (cpu_ce_pulse),
	.CEK_N  (),
	.CE7_N  (),
	.CER_N  (),
	.PRE_RD (),
	.PRE_WR (),
	.HSM    (),
	.O      (),
	.AUD_LDATA (cpu_aud_l),
	.AUD_RDATA (cpu_aud_r),
	// Savestate auto_ss (HUC_SS_BITS). Connected to u_huc_ss_adaptor above.
	.SS_DO     (huc_ss_out),
	.SS_DI     (huc_ss_in),
	.SS_WR     (huc_ss_wr)
);

// =====================================================================
// Audio mix. MAME BoogieWings weights: ym=0.32, oki0=0.56, oki1=0.12. In 4.4 fixed
// point (MAME_GAIN_*):
//   ym = 0.32 × 16 = 5.12 → 0x05
//   oki0 = 0.56 × 16 = 8.96 → 0x09
//   oki1 = 0.12 × 16 = 1.92 → 0x02
// =====================================================================
// Mixer: Q4.4 mul + sum + saturation, no extra filters (no sndchain/dcrm/pole).
// Weights gain_fm/oki0/oki1 from the OSD (8-bit Q4.4). Samples (ChannelDataExt):
//   OPM (jt51) ym_left/ym_right = 16-bit signed
//   OKI (jt6295) oki*_sound = 14-bit signed → sign-extended to 16-bit
// mul = signed × unsigned 8-bit → 24-bit signed
// accumulate at 18-bit, shift >>> 4 (Q4.4 fractional part), saturate to 16-bit.
// =====================================================================
wire signed [15:0] oki0_ext = { {2{oki0_sound[13]}}, oki0_sound };
wire signed [15:0] oki1_ext = { {2{oki1_sound[13]}}, oki1_sound };

wire signed [24:0] ym_l_mul   = $signed(ym_left)  * $signed({1'b0, gain_fm});
wire signed [24:0] ym_r_mul   = $signed(ym_right) * $signed({1'b0, gain_fm});
wire signed [24:0] oki0_mul   = $signed(oki0_ext) * $signed({1'b0, gain_oki0});
wire signed [24:0] oki1_mul   = $signed(oki1_ext) * $signed({1'b0, gain_oki1});

// 2-stage pipeline: the mul→shift→sum→reg path does not meet timing at 96 MHz in
// 1 clk. Stage 1 registers the shifted products (absorbed into the DSP output
// register), stage 2 sums. +1 clk of audio latency = negligible.
reg signed [20:0] ym_l_s, ym_r_s, oki0_s, oki1_s;
always @(posedge clk) begin
	ym_l_s <= ym_l_mul >>> 4;
	ym_r_s <= ym_r_mul >>> 4;
	oki0_s <= oki0_mul >>> 4;
	oki1_s <= oki1_mul >>> 4;
end

reg signed [19:0] mix_l, mix_r;
always @(posedge clk) begin
	mix_l <= ym_l_s + oki0_s + oki1_s;
	mix_r <= ym_r_s + oki0_s + oki1_s;
end

function signed [15:0] sat16(input signed [19:0] v);
	if      (v >  $signed(20'sd32767))  sat16 = 16'sd32767;
	else if (v < -$signed(20'sd32768))  sat16 = -16'sd32768;
	else                                sat16 = v[15:0];
endfunction

// Presence (OSD O[24:23]): treble shelving on the mix, output = dry + g*(dry - lp).
// lp = 1-pole low-pass at 192 kHz (96 MHz / 500) with alpha 1/16 -> cutoff ~2 kHz.
// g = 0, 7/16, 1, 29/16 -> 0 / +3 / +6 / +9 dB above ~2 kHz, bass unchanged.
// With Off (g = 0) the output equals the incoming mix (plus latency).
// 3-stage pipeline (in a single cycle it does not meet timing at 96 MHz): 1) registered
// dry and subtraction, 2) product, 3) sum + saturation. 4 clk of latency: irrelevant.
reg signed [15:0] dry_l, dry_r;
always @(posedge clk) begin
	dry_l <= sat16(mix_l);
	dry_r <= sat16(mix_r);
end
reg  [8:0] pr_div = 9'd0;
wire       pr_ce  = (pr_div == 9'd499);
always @(posedge clk) if (!pause) pr_div <= pr_ce ? 9'd0 : pr_div + 9'd1;

// Correction towards MAME (4 cascaded biquads at 192 kHz), derived from aligned
// MAME/core recordings of the attract sequence. See mix_eq.sv for the parameters.
// ce gated here too: in pause pr_div stops and pr_ce could stay high.
wire signed [15:0] eq_l, eq_r;
mix_eq u_mix_eq (
	.clk   (clk),
	.reset (reset),
	.ce    (pr_ce & ~pause),
	.in_l  (dry_l),
	.in_r  (dry_r),
	.out_l (eq_l),
	.out_r (eq_r)
);

reg signed [19:0] lp_l = 20'sd0, lp_r = 20'sd0;   // Q16.4
always @(posedge clk) begin
	if (reset) begin
		lp_l <= 20'sd0;
		lp_r <= 20'sd0;
	end else if (pr_ce && !pause) begin
		lp_l <= lp_l + (($signed({eq_l, 4'd0}) - lp_l) >>> 4);
		lp_r <= lp_r + (($signed({eq_r, 4'd0}) - lp_r) >>> 4);
	end
end
reg [4:0] pr_g;
always @(*) begin
	case (osd_presence)
		2'd1:    pr_g = 5'd7;    // +3 dB
		2'd2:    pr_g = 5'd16;   // +6 dB
		2'd3:    pr_g = 5'd29;   // +9 dB
		default: pr_g = 5'd0;    // Off
	endcase
end
reg  signed [16:0] hp_l, hp_r;          // stage 1: treble = eq - low-pass
reg  signed [15:0] dry1_l, dry1_r;
always @(posedge clk) begin
	hp_l   <= eq_l - (lp_l >>> 4);
	hp_r   <= eq_r - (lp_r >>> 4);
	dry1_l <= eq_l;
	dry1_r <= eq_r;
end
reg  signed [22:0] boost_l, boost_r;    // stage 2: product with the gain
reg  signed [15:0] dry2_l, dry2_r;
always @(posedge clk) begin
	boost_l <= hp_l * $signed({1'b0, pr_g});
	boost_r <= hp_r * $signed({1'b0, pr_g});
	dry2_l  <= dry1_l;
	dry2_r  <= dry1_r;
end
reg  signed [15:0] out_l, out_r;        // stage 3: sum + saturation
always @(posedge clk) begin
	out_l <= sat16(dry2_l + (boost_l >>> 4));
	out_r <= sat16(dry2_r + (boost_r >>> 4));
end

assign audio_l = out_l;
assign audio_r = out_r;

endmodule
