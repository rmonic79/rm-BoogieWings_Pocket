derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# ============================================================
# BoogieWings audio (module boogwings_audio, instance emu|game|u_audio).
# HuC6280 + YM2151 (jt51) + 2x OKI (jt6295), all CE-gated by counters on
# clk_sys 96MHz (ce_* dividers in Template.sv).
# Per-instance multicycle with the REAL ratio of each divider (intra-domain).
# NO global multicycle: the mixer (mix_l/mix_r) runs on the PLAIN clock = real
# single-cycle, solved in RTL with a pipeline. Crossings between different enables stay 1-ck.
# ============================================================
# HuC6280 u_cpu: no multicycle on the whole CPU (ce_audio = 96/12 would give 12).
# POCKET: the sound program runs in CSH (fast mode): the CPU advances every
# 6 clocks and its internal counters (CPU_CLK_CNT, IO_CLK_CNT) on every clock, so
# 12 is too wide. On the Pocket (5CEBA4F23C8, slower) the HuC paths are
# analysed single-cycle, the most severe case.
# POCKET: CORRECT multicycle only inside the CPU core (HUC6280_CPU:CORE).
# All its registers load only with EN (= CPU_CE & RDY) or CE (= CPU_CE),
# 1-cycle pulses at least 6 clocks apart (fast) or 24 (slow), or with SS_WR
# (restore, data from SS_DI outside the core). Exception: the NMI synchroniser
# (NMI_SYNC, OLD_NMI_N) works on every clock -> excluded. This holds for all the
# processes of HUC6280_CPU/_MC/_AG/_ALU. Paths to/from outside the core stay
# single-cycle (CPU_CLK_CNT/IO_CLK_CNT counters, timer, IO).
set huc_core [remove_from_collection [get_registers -nowarn {*u_audio|HUC6280:u_cpu|HUC6280_CPU:CORE|*}]                 [get_registers -nowarn {*u_audio|HUC6280:u_cpu|HUC6280_CPU:CORE|NMI_SYNC *u_audio|HUC6280:u_cpu|HUC6280_CPU:CORE|OLD_NMI_N}]]
set_multicycle_path -setup -from $huc_core -to $huc_core 6
set_multicycle_path -hold  -from $huc_core -to $huc_core 5
# YM2151 jt51 u_ym : ce_ym = 96/27 (cen_p1 = /54) -> use the faster one, 27
set_multicycle_path -setup -from [get_registers {*u_ym*}] -to [get_registers {*u_ym*}] 27
set_multicycle_path -hold  -from [get_registers {*u_ym*}] -to [get_registers {*u_ym*}] 26
# OKI#0 jt6295 u_oki0 : ce_oki0 = 96/95 -> setup 95, hold 94
set_multicycle_path -setup -from [get_registers {*u_oki0*}] -to [get_registers {*u_oki0*}] 95
set_multicycle_path -hold  -from [get_registers {*u_oki0*}] -to [get_registers {*u_oki0*}] 94
# OKI#1 jt6295 u_oki1 : ce_oki1 = 96/48 -> setup 48, hold 47
set_multicycle_path -setup -from [get_registers {*u_oki1*}] -to [get_registers {*u_oki1*}] 48
set_multicycle_path -hold  -from [get_registers {*u_oki1*}] -to [get_registers {*u_oki1*}] 47

# ============================================================
# DOWNLOAD decrypt path (de102 + deco56).
# Active ONLY while the ROM loads: ioctl_addr/dout_raw from hps_io are static
# during play. hps_io delivers 1 word, the bridge raises prog_wr and holds
# hps_io via ioctl_wait (prog_ack) -> many clocks pass between two words.
# The decrypt->write-data path does NOT need 1 ck @96MHz. Multicycle 4 (41.6 ns).
# It is NOT a gameplay path: no runtime impact, no pacing risk.
# ============================================================
# The -from is anchored to STABLE names, robust to refits (the fitter renames the
# internal decrypt nodes): hps_io ioctl_addr (root of the whole download fan-out)
# and the bridge prog_wr. The -to covers the download endpoints (prog_*, ddr_dl_*,
# dl_data_word, audio_rom_*, SDRAM outputs).
# POCKET: deco56_ioctl_decrypt_reg (tables in M10K) sits AFTER the download
# register: from its tables to the consumers (prog_*, ddr_dl_*) the data has only
# ONE cycle (ioctl_wr arrives one edge later). So *deco56_ioctl_decrypt* is NOT in
# the -from: a multicycle 4 would hide a real violation there (corrupted tiles).
set DL_FROM {*hps_io*ioctl_addr* *sdram_bridge*prog_wr*}
set DL_TO   {*sdram_bridge*prog_* *ddr_dl_* *dl_data_word* \
             *audio_rom_* *u_sdram_jt|sdram_a* *u_sdram_jt|sdram_*}
set_multicycle_path -setup -from [get_registers $DL_FROM] -to [get_registers $DL_TO] 4
set_multicycle_path -hold  -from [get_registers $DL_FROM] -to [get_registers $DL_TO] 3

# ============================================================
# POCKET: audio gains chosen in the menu (status[10:7] FM, [14:11] OKI0,
# [18:15] OKI1, [24:23] presence): quasi-static configuration values that
# change only from the menu. False path from these status bits only.
# ============================================================
set_false_path -from [get_registers -nowarn {*hps_io|status[7] *hps_io|status[8] *hps_io|status[9] *hps_io|status[10]                                               *hps_io|status[11] *hps_io|status[12] *hps_io|status[13] *hps_io|status[14]                                               *hps_io|status[15] *hps_io|status[16] *hps_io|status[17] *hps_io|status[18]                                               *hps_io|status[23] *hps_io|status[24]}]

# ============================================================
# POCKET: savestate. save_state_data raises read/write/query towards the slaves
# one cycle AFTER memory_stream and lowers them together; address, data and
# select (chunk_address, write_data, chunk_index) change only while the request is low.
# Each slave uses them only with access() (select==idx & request) or in a register
# read only on the following cycle together with the access (single-buffer YM
# adapter): true for all the slaves of the core. Hence 2 cycles from those
# registers to everything outside u_save_state.
# ============================================================
set ss_src [get_registers -nowarn {*u_save_state|memory_stream:memory_stream|chunk_address[*]                                    *u_save_state|memory_stream:memory_stream|write_data[*]                                    *u_save_state|memory_stream:memory_stream|chunk_index[*]}]
set ss_dst [remove_from_collection [get_keepers *] [get_keepers -nowarn {*u_save_state|*}]]
set_multicycle_path -setup -from $ss_src -to $ss_dst 2
set_multicycle_path -hold  -from $ss_src -to $ss_dst 1

# ============================================================
# POCKET: 68000 fx68k. Ir/Ird load only with enT1 (enPhi1 & T4);
# nanoAddr/microAddr only with enT1 (or pwrUp, constant); rIllegal/rLineA/
# rLineF/rPriv only with enT3 (enPhi1 & T2). Between an enT1 and the next enT1
# or enT3 there is always at least one enPhi2 (T4->T1->T2 and T2->T3->T4), i.e.
# at least 2 clocks: data launched from Ir/Ird has 2 cycles. This is the known
# fx68k constraint (the same one used by the MiSTer Genesis core).
# ============================================================
set fx_ir  [get_registers -nowarn {*fx68k:cpu_core|Ir[*] *fx68k:cpu_core|Ird[*]}]
set fx_dst [get_registers -nowarn {*fx68k:cpu_core|nanoAddr[*] *fx68k:cpu_core|microAddr[*] *fx68k:cpu_core|sequencer:sequencer|rIllegal *fx68k:cpu_core|sequencer:sequencer|rLineA *fx68k:cpu_core|sequencer:sequencer|rLineF *fx68k:cpu_core|sequencer:sequencer|rPriv}]
set_multicycle_path -setup -from $fx_ir -to $fx_dst 2
set_multicycle_path -hold  -from $fx_ir -to $fx_dst 1

# ============================================================
# POCKET: per-pixel video pipeline (timing on the Pocket).
# hcnt/vcnt change only on the ce_pix edge, one every 14 clk (Template.sv).
# The sprite outputs pxl0_r/pxl1_r/pxl1a_r (bw_sprites) change only 2 clk after
# an hcnt change (line buffer read at render_x; drawing always writes a buffer
# other than the one displayed: fill <= 10, build = disp+fill+1 mod 12) or in
# hblank. The colour pipeline (mix registers -> pal_buf -> stages A..E ->
# rgb_q, 9 clk from hcnt) advances on every clock; pause_overlay and VGA_R are
# combinational; pocket_video samples the RGB only at ce_pix (14 clk). One extra
# cycle on the pxl -> mix segment brings the latency to 10 out of 14: same pixel.
# If Quartus maps the chain pixel_alpha_r -> alpha_d -> ... to an M10K shift
# register (altshift_taps), its datain_reg IS the pixel_alpha_r stage: same rule.
# Pause overlay: vcnt -> msg_rom address, same rule (latency < 14).
# ============================================================
set px_src  [get_registers -nowarn {*bw_sprites:*|pxl0_r[*] *bw_sprites:*|pxl1_r[*] *bw_sprites:*|pxl1a_r[*]}]
set mix_dst [get_registers -nowarn {*boogwings_top:game|top_pal_idx_r[*] *boogwings_top:game|bot_pal_idx_r[*] *boogwings_top:game|blend_en_r *boogwings_top:game|sub_blend_r *boogwings_top:game|pixel_alpha_r[*] *boogwings_top:game|*pal_buf_*porta_address_reg* *boogwings_top:game|*pixel_alpha_r_rtl_*|*porta_datain_reg*}]
set_multicycle_path -setup -from $px_src -to $mix_dst 2
set_multicycle_path -hold  -from $px_src -to $mix_dst 1
set vc_src  [get_registers -nowarn {*emu:emu|vcnt[*]}]
set msg_dst [get_registers -nowarn {*u_pause_ovl|pause_text:*|*msg_rom*porta_address_reg*}]
set_multicycle_path -setup -from $vc_src -to $msg_dst 2
set_multicycle_path -hold  -from $vc_src -to $msg_dst 1
