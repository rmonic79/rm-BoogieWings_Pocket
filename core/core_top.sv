// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) Umberto Parisi (rmonic79).
//
// core_top — the Pocket "sys" for a MiSTer core.
//
// apf_top (Analogue, left untouched) instantiates this module as "ic"; inside
// it sits emu, i.e. the MiSTer core as it is, with the same ports that
// sys_top gives it on MiSTer:
//
//   CLK_50M        <- clk_74a (the core PLL is regenerated for 74.25 MHz)
//   RESET          <- reset from the Pocket host commands 0010/0011
//   HPS_BUS        <- pocket_hps: plays the role of the HPS (hps_io stays original)
//   SDRAM_*        <- Pocket SDRAM, direct pins
//   DDRAM_*        <- pocket_ddram -> pocket_psram (the two PSRAMs, 32 bits)
//   CLK_VIDEO/CE_PIXEL/VGA_* -> pocket_video -> Pocket scaler
//   AUDIO_L/R      -> I2S 48 kHz (sound_i2s by Adam Gastineau, MIT)
//   CLK_AUDIO      <- 24.576 MHz (pocket_pll_audio)
//
// The core-specific settings are in pocket_cfg.vh (pocket/ folder of the
// project).

`default_nettype none

module core_top (

input   wire            clk_74a,
input   wire            clk_74b,

inout   wire    [7:0]   cart_tran_bank2,
output  wire            cart_tran_bank2_dir,
inout   wire    [7:0]   cart_tran_bank3,
output  wire            cart_tran_bank3_dir,
inout   wire    [7:0]   cart_tran_bank1,
output  wire            cart_tran_bank1_dir,
inout   wire    [7:4]   cart_tran_bank0,
output  wire            cart_tran_bank0_dir,
inout   wire            cart_tran_pin30,
output  wire            cart_tran_pin30_dir,
output  wire            cart_pin30_pwroff_reset,
inout   wire            cart_tran_pin31,
output  wire            cart_tran_pin31_dir,

input   wire            port_ir_rx,
output  wire            port_ir_tx,
output  wire            port_ir_rx_disable,

inout   wire            port_tran_si,
output  wire            port_tran_si_dir,
inout   wire            port_tran_so,
output  wire            port_tran_so_dir,
inout   wire            port_tran_sck,
output  wire            port_tran_sck_dir,
inout   wire            port_tran_sd,
output  wire            port_tran_sd_dir,

output  wire    [21:16] cram0_a,
inout   wire    [15:0]  cram0_dq,
input   wire            cram0_wait,
output  wire            cram0_clk,
output  wire            cram0_adv_n,
output  wire            cram0_cre,
output  wire            cram0_ce0_n,
output  wire            cram0_ce1_n,
output  wire            cram0_oe_n,
output  wire            cram0_we_n,
output  wire            cram0_ub_n,
output  wire            cram0_lb_n,

output  wire    [21:16] cram1_a,
inout   wire    [15:0]  cram1_dq,
input   wire            cram1_wait,
output  wire            cram1_clk,
output  wire            cram1_adv_n,
output  wire            cram1_cre,
output  wire            cram1_ce0_n,
output  wire            cram1_ce1_n,
output  wire            cram1_oe_n,
output  wire            cram1_we_n,
output  wire            cram1_ub_n,
output  wire            cram1_lb_n,

output  wire    [12:0]  dram_a,
output  wire    [1:0]   dram_ba,
inout   wire    [15:0]  dram_dq,
output  wire    [1:0]   dram_dqm,
output  wire            dram_clk,
output  wire            dram_cke,
output  wire            dram_ras_n,
output  wire            dram_cas_n,
output  wire            dram_we_n,

output  wire    [16:0]  sram_a,
inout   wire    [15:0]  sram_dq,
output  wire            sram_oe_n,
output  wire            sram_we_n,
output  wire            sram_ub_n,
output  wire            sram_lb_n,

input   wire            vblank,

output  wire            dbg_tx,
input   wire            dbg_rx,

output  wire            user1,
input   wire            user2,

inout   wire            aux_sda,
output  wire            aux_scl,

output  wire            vpll_feed,

output  wire    [23:0]  video_rgb,
output  wire            video_rgb_clock,
output  wire            video_rgb_clock_90,
output  wire            video_de,
output  wire            video_skip,
output  wire            video_vs,
output  wire            video_hs,

output  wire            audio_mclk,
input   wire            audio_adc,
output  wire            audio_dac,
output  wire            audio_lrck,

output  wire            bridge_endian_little,
input   wire    [31:0]  bridge_addr,
input   wire            bridge_rd,
output  reg     [31:0]  bridge_rd_data,
input   wire            bridge_wr,
input   wire    [31:0]  bridge_wr_data,

input   wire    [31:0]  cont1_key,
input   wire    [31:0]  cont2_key,
input   wire    [31:0]  cont3_key,
input   wire    [31:0]  cont4_key,
input   wire    [31:0]  cont1_joy,
input   wire    [31:0]  cont2_joy,
input   wire    [31:0]  cont3_joy,
input   wire    [31:0]  cont4_joy,
input   wire    [15:0]  cont1_trig,
input   wire    [15:0]  cont2_trig,
input   wire    [15:0]  cont3_trig,
input   wire    [15:0]  cont4_trig
);

`include "pocket_cfg.vh"

`default_nettype wire

// ============================================================ unused pins
// (safe values from the Analogue template)
assign port_ir_tx = 0;
assign port_ir_rx_disable = 1;
assign bridge_endian_little = 0;

assign cart_tran_bank3 = 8'hzz;
assign cart_tran_bank3_dir = 1'b0;
assign cart_tran_bank2 = 8'hzz;
assign cart_tran_bank2_dir = 1'b0;
assign cart_tran_bank1 = 8'hzz;
assign cart_tran_bank1_dir = 1'b0;
assign cart_tran_bank0 = 4'hf;
assign cart_tran_bank0_dir = 1'b1;
assign cart_tran_pin30 = 1'b0;
assign cart_tran_pin30_dir = 1'bz;
assign cart_pin30_pwroff_reset = 1'b0;
assign cart_tran_pin31 = 1'bz;
assign cart_tran_pin31_dir = 1'b0;

assign port_tran_so = 1'bz;
assign port_tran_so_dir = 1'b0;
assign port_tran_si = 1'bz;
assign port_tran_si_dir = 1'b0;
assign port_tran_sck = 1'bz;
assign port_tran_sck_dir = 1'b0;
assign port_tran_sd = 1'bz;
assign port_tran_sd_dir = 1'b0;

assign sram_a = 'h0;
assign sram_dq = {16{1'bZ}};
assign sram_oe_n  = 1;
assign sram_we_n  = 1;
assign sram_ub_n  = 1;
assign sram_lb_n  = 1;

assign dbg_tx = 1'bZ;
assign user1 = 1'bZ;
assign aux_scl = 1'bZ;
assign vpll_feed = 1'bZ;

// ============================================================ emu clock
// hps_io sends the emu clock (clk_sys) back on HPS_BUS[36]: the whole "HPS"
// side and the PSRAM run on it, as on MiSTer (DDRAM_CLK = clk_sys).
wire [48:0] hps_bus;
wire        clk_sys = hps_bus[36];

// ============================================================ host commands
wire        reset_n;
wire [31:0] cmd_bridge_rd_data;

// POCKET: boot status as in the Analogue template (template core_top.v:
// status_boot_done = status_setup_done = core PLL locked, synchronised).
// The core must not keep answering "booting" (0x0001) to Request Status: after 10
// "booting" answers the Pocket stops with "Fatal error in APF: RS: Host commands
// ignored". emu exports the locked signal of its PLL on POCKET_PLL_LOCKED.
// The PSRAM controller (clk_sys) has no start-up sequence: it is ready as soon as
// the PLL locks.
wire emu_pll_locked;
wire emu_pll_locked_s;
synch_3 s_lock(emu_pll_locked, emu_pll_locked_s, clk_74a);

wire        status_boot_done  = emu_pll_locked_s;
wire        status_setup_done = emu_pll_locked_s;   // rising edge -> 0x0140 Ready to run
wire        status_running    = reset_n;

wire        dataslot_requestread;
wire [15:0] dataslot_requestread_id;
wire        dataslot_requestwrite;
wire [15:0] dataslot_requestwrite_id;
wire [31:0] dataslot_requestwrite_size;
wire        dataslot_update;
wire [15:0] dataslot_update_id;
wire [31:0] dataslot_update_size;
wire        dataslot_allcomplete;
wire [31:0] rtc_epoch_seconds, rtc_date_bcd, rtc_time_bcd;
wire        rtc_valid;
wire        savestate_start, savestate_load;
wire        savestate_start_ack, savestate_start_busy, savestate_start_ok, savestate_start_err;
wire        savestate_load_ack, savestate_load_busy, savestate_load_ok, savestate_load_err;
wire        osnotify_inmenu;
wire        target_dataslot_ack, target_dataslot_done;
wire  [2:0] target_dataslot_err;
wire [31:0] datatable_q;

core_bridge_cmd icb (
	.clk                        ( clk_74a ),
	.reset_n                    ( reset_n ),

	.bridge_endian_little       ( bridge_endian_little ),
	.bridge_addr                ( bridge_addr ),
	.bridge_rd                  ( bridge_rd ),
	.bridge_rd_data             ( cmd_bridge_rd_data ),
	.bridge_wr                  ( bridge_wr ),
	.bridge_wr_data             ( bridge_wr_data ),

	.status_boot_done           ( status_boot_done ),
	.status_setup_done          ( status_setup_done ),
	.status_running             ( status_running ),

	.dataslot_requestread       ( dataslot_requestread ),
	.dataslot_requestread_id    ( dataslot_requestread_id ),
	.dataslot_requestread_ack   ( 1'b1 ),
	.dataslot_requestread_ok    ( 1'b1 ),

	.dataslot_requestwrite      ( dataslot_requestwrite ),
	.dataslot_requestwrite_id   ( dataslot_requestwrite_id ),
	.dataslot_requestwrite_size ( dataslot_requestwrite_size ),
	.dataslot_requestwrite_ack  ( 1'b1 ),
	.dataslot_requestwrite_ok   ( 1'b1 ),

	.dataslot_update            ( dataslot_update ),
	.dataslot_update_id         ( dataslot_update_id ),
	.dataslot_update_size       ( dataslot_update_size ),

	.dataslot_allcomplete       ( dataslot_allcomplete ),

	.rtc_epoch_seconds          ( rtc_epoch_seconds ),
	.rtc_date_bcd               ( rtc_date_bcd ),
	.rtc_time_bcd               ( rtc_time_bcd ),
	.rtc_valid                  ( rtc_valid ),

	.savestate_supported        ( CFG_SS_ENABLE ? 1'b1 : 1'b0 ),
	.savestate_addr             ( 32'h20000000 ),
	.savestate_size             ( CFG_SS_SIZE ),
	.savestate_maxloadsize      ( CFG_SS_SIZE ),

	.savestate_start            ( savestate_start ),
	.savestate_start_ack        ( savestate_start_ack ),
	.savestate_start_busy       ( savestate_start_busy ),
	.savestate_start_ok         ( savestate_start_ok ),
	.savestate_start_err        ( savestate_start_err ),

	.savestate_load             ( savestate_load ),
	.savestate_load_ack         ( savestate_load_ack ),
	.savestate_load_busy        ( savestate_load_busy ),
	.savestate_load_ok          ( savestate_load_ok ),
	.savestate_load_err         ( savestate_load_err ),

	.osnotify_inmenu            ( osnotify_inmenu ),

	.target_dataslot_read       ( 1'b0 ),
	.target_dataslot_write      ( 1'b0 ),
	.target_dataslot_getfile    ( 1'b0 ),
	.target_dataslot_openfile   ( 1'b0 ),
	.target_dataslot_ack        ( target_dataslot_ack ),
	.target_dataslot_done       ( target_dataslot_done ),
	.target_dataslot_err        ( target_dataslot_err ),
	.target_dataslot_id         ( 16'd0 ),
	.target_dataslot_slotoffset ( 32'd0 ),
	.target_dataslot_bridgeaddr ( 32'd0 ),
	.target_dataslot_length     ( 32'd0 ),
	.target_buffer_param_struct ( 32'd0 ),
	.target_buffer_resp_struct  ( 32'd0 ),

	.datatable_addr             ( 10'd0 ),
	.datatable_wren             ( 1'b0 ),
	.datatable_data             ( 32'd0 ),
	.datatable_q                ( datatable_q )
);

// ============================================================ bridge
wire [31:0] pb_rd_data, pb_reg_data;
wire [25:0] pb_stage_hi;   // length of the .rom written by the bridge (clk_74a)
wire        rom_wr_req;    // the Pocket is about to (re)write the .rom slot

always @(*) begin
	casex (bridge_addr)
		32'hF8xxxxxx: bridge_rd_data = cmd_bridge_rd_data;
		32'h2xxxxxxx: bridge_rd_data = pb_rd_data;      // savestate: data of the previous read (prefetch)
		32'h3xxxxxxx: bridge_rd_data = pb_reg_data;     // registers: data of the current address
		default:      bridge_rd_data = 32'd0;
	endcase
end

wire [127:0] cfg_status;
wire  [63:0] cfg_dip;
wire  [31:0] cfg_mod;
wire         cfg_tog;
wire [127:0] cfg_pulse;
wire         cfg_pulse_tog;
wire         mon_wr, mon_rd;
reg          mon_wr_tog = 0, mon_rd_tog = 0;
always @(posedge clk_sys) begin
	if (mon_wr) mon_wr_tog <= ~mon_wr_tog;
	if (mon_rd) mon_rd_tog <= ~mon_rd_tog;
end

wire        pb_req, pb_we, pb_ack;
wire [22:0] pb_addr;
wire [31:0] pb_wdata;
wire  [3:0] pb_be;
wire [31:0] ps_rdata;

pocket_bridge #(
	.STAGE_BYTE     ( CFG_STAGE_BYTE ),
	.SS_BYTE        ( CFG_SS_BYTE ),
	.SS_SIZE        ( CFG_SS_SIZE ),
	.SS_ENABLE      ( CFG_SS_ENABLE ),
	.SS_SAVE_BIT    ( CFG_SS_SAVE_BIT ),
	.SS_LOAD_BIT    ( CFG_SS_LOAD_BIT ),
	.STATUS_DEFAULT ( CFG_STATUS_DEFAULT ),
	.DIP_DEFAULT    ( CFG_DIP_DEFAULT ),
	.MOD_DEFAULT    ( CFG_MOD_DEFAULT )
) u_bridge (
	.clk                  ( clk_74a ),
	.bridge_addr          ( bridge_addr ),
	.bridge_rd            ( bridge_rd ),
	.bridge_wr            ( bridge_wr ),
	.bridge_wr_data       ( bridge_wr_data ),
	.rd_data              ( pb_rd_data ),
	.reg_rd_data          ( pb_reg_data ),
	.stage_hi             ( pb_stage_hi ),
	.stage_clr            ( rom_wr_req ),

	.status               ( cfg_status ),
	.dip                  ( cfg_dip ),
	.mod                  ( cfg_mod ),
	.cfg_tog              ( cfg_tog ),
	.pulse                ( cfg_pulse ),
	.pulse_tog            ( cfg_pulse_tog ),

	.savestate_start      ( savestate_start ),
	.savestate_start_ack  ( savestate_start_ack ),
	.savestate_start_busy ( savestate_start_busy ),
	.savestate_start_ok   ( savestate_start_ok ),
	.savestate_start_err  ( savestate_start_err ),
	.savestate_load       ( savestate_load ),
	.savestate_load_ack   ( savestate_load_ack ),
	.savestate_load_busy  ( savestate_load_busy ),
	.savestate_load_ok    ( savestate_load_ok ),
	.savestate_load_err   ( savestate_load_err ),

	.mon_wr_tog           ( mon_wr_tog ),
	.mon_rd_tog           ( mon_rd_tog ),

	.ps_clk               ( clk_sys ),
	.ps_req               ( pb_req ),
	.ps_we                ( pb_we ),
	.ps_addr              ( pb_addr ),
	.ps_wdata             ( pb_wdata ),
	.ps_be                ( pb_be ),
	.ps_ack               ( pb_ack ),
	.ps_rdata             ( ps_rdata )
);

// ============================================================ start-up
// the .rom (data slot CFG_ROM_SLOT) is in PSRAM; when the Pocket leaves
// reset (0x0011) the load into emu starts, once only.
reg  [31:0] rom_size = 0;
reg         rom_seen = 0;
reg         started  = 0;
reg         start_tog = 0;
assign rom_wr_req = dataslot_requestwrite && dataslot_requestwrite_id == CFG_ROM_SLOT;
always @(posedge clk_74a) begin
	if (rom_wr_req) begin
		rom_size <= dataslot_requestwrite_size;
		rom_seen <= 1;
		started  <= 0;   // POCKET: a new write of the slot = a new load (reload without reloading the bitstream)
	end
	// POCKET: the .rom length does not come only from the parameter of command
	// 0x0082: if the bridge wrote beyond it, the last written byte + 4 is used
	// (the same value when the Pocket passes the file size).
	if (!started && (rom_seen || pb_stage_hi != 26'd0) && dataslot_allcomplete && reset_n) begin
		started   <= 1;
		start_tog <= ~start_tog;
		if ({6'd0, pb_stage_hi} > rom_size) rom_size <= {6'd0, pb_stage_hi};
	end
end

// ============================================================ controls
// MiSTer joystick: [0]=R [1]=L [2]=D [3]=U, [4+i] = button i of the CONF_STR (J1)
function [31:0] map_joy(input [31:0] k);
	integer i;
	begin
		map_joy = 32'd0;
		map_joy[0] = k[3];
		map_joy[1] = k[2];
		map_joy[2] = k[1];
		map_joy[3] = k[0];
		for (i = 0; i < 12; i = i + 1)
			if (CFG_BTN_MAP[i*5+4]) map_joy[4+i] = k[CFG_BTN_MAP[i*5 +: 4]];
	end
endfunction

// Pocket keys after the autofire (pocket_autofire.sv; instances below, after vga_vs).
wire [31:0] cont1_af, cont2_af;

reg  [31:0] joy0 = 0, joy1 = 0;
reg         joy_tog = 0;
always @(posedge clk_74a) begin
	if (map_joy(cont1_af) != joy0 || map_joy(cont2_af) != joy1) begin
		joy0    <= map_joy(cont1_af);
		joy1    <= map_joy(cont2_af);
		joy_tog <= ~joy_tog;
	end
end

// ============================================================ HPS
wire        hps_strobe, hps_uio, hps_fpga;
wire [15:0] hps_din;
wire        hr_req, hr_ack;
wire [22:0] hr_addr;
wire        hps_loading, hps_loaded;

pocket_hps #(
	.ROM_INDEX ( CFG_ROM_INDEX ),
	.MOD_INDEX ( CFG_MOD_INDEX ),
	.MOD_LEN   ( CFG_MOD_LEN ),
	.DIP_LEN   ( CFG_DIP_LEN ),
	.STAGE_W   ( CFG_STAGE_BYTE[24:2] )
) u_hps (
	.clk         ( clk_sys ),
	.io_strobe   ( hps_strobe ),
	.io_uio      ( hps_uio ),
	.io_fpga     ( hps_fpga ),
	.io_din      ( hps_din ),
	.io_wait     ( hps_bus[37] ),

	.cfg_tog     ( cfg_tog ),
	.status_in   ( cfg_status ),
	.dip_in      ( cfg_dip ),
	.mod_in      ( cfg_mod ),
	.pulse_tog   ( cfg_pulse_tog ),
	.pulse_in    ( cfg_pulse ),
	.joy_tog     ( joy_tog ),
	.joy0_in     ( joy0 ),
	.joy1_in     ( joy1 ),
	.start_tog   ( start_tog ),
	.rom_size_in ( rom_size ),

	.ps_req      ( hr_req ),
	.ps_addr     ( hr_addr ),
	.ps_ack      ( hr_ack ),
	.ps_rdata    ( ps_rdata ),

	.loading     ( hps_loading ),
	.loaded      ( hps_loaded )
);

// HPS_BUS as in sys_top: {fb_en, sl, f1, HDMI_TX_VS, clk_100m, clk_ihdmi,
// ce_hpix, hde_emu, hhs_fix, hvs_fix, io_wait, clk_sys, io_fpga, io_uio,
// io_strobe, io_wide, io_din, io_dout}. [37], [36], [32] and [15:0] are driven
// by hps_io; video_calc (command 0x23) is never queried: its inputs are 0.
assign hps_bus[48:38] = 11'd0;
assign hps_bus[35]    = hps_fpga;
assign hps_bus[34]    = hps_uio;
assign hps_bus[33]    = hps_strobe;
assign hps_bus[31:16] = hps_din;

// Pocket reset in the emu clock domain
reg [2:0] rst_s = 3'b111;
always @(posedge clk_sys) rst_s <= {rst_s[1:0], ~reset_n};
wire emu_reset = rst_s[2];

// ============================================================ PSRAM port 3
// Port 3 of pocket_psram is not used by this core: its inputs are tied to 0.
wire        ax_req, ax_we, ax_ack;
wire [22:0] ax_addr;
wire [31:0] ax_wdata;
wire  [3:0] ax_be;
assign ax_req = 1'b0;  assign ax_we = 1'b0;  assign ax_addr = 23'd0;
assign ax_wdata = 32'd0;  assign ax_be = 4'd0;

// ============================================================ PSRAM
wire        dd_req, dd_we, dd_ack;
wire [22:0] dd_addr;
wire [31:0] dd_wdata;
wire  [3:0] dd_be;

pocket_psram #(.T_ACC(CFG_PSRAM_TACC)) u_psram (
	.clk      ( clk_sys ),

	.p0_req   ( dd_req ),  .p0_we ( dd_we ), .p0_addr ( dd_addr ),
	.p0_wdata ( dd_wdata ), .p0_be ( dd_be ), .p0_ack ( dd_ack ),

	.p1_req   ( pb_req ),  .p1_we ( pb_we ), .p1_addr ( pb_addr ),
	.p1_wdata ( pb_wdata ), .p1_be ( pb_be ), .p1_ack ( pb_ack ),

	.p2_req   ( hr_req ),  .p2_we ( 1'b0 ), .p2_addr ( hr_addr ),
	.p2_wdata ( 32'd0 ),   .p2_be ( 4'hF ), .p2_ack ( hr_ack ),

	.p3_req   ( ax_req ),  .p3_we ( ax_we ), .p3_addr ( ax_addr ),
	.p3_wdata ( ax_wdata ), .p3_be ( ax_be ), .p3_ack ( ax_ack ),

	.rdata    ( ps_rdata ),

	.cram0_a ( cram0_a ), .cram0_dq ( cram0_dq ), .cram0_clk ( cram0_clk ),
	.cram0_adv_n ( cram0_adv_n ), .cram0_cre ( cram0_cre ),
	.cram0_ce0_n ( cram0_ce0_n ), .cram0_ce1_n ( cram0_ce1_n ),
	.cram0_oe_n ( cram0_oe_n ), .cram0_we_n ( cram0_we_n ),
	.cram0_ub_n ( cram0_ub_n ), .cram0_lb_n ( cram0_lb_n ),

	.cram1_a ( cram1_a ), .cram1_dq ( cram1_dq ), .cram1_clk ( cram1_clk ),
	.cram1_adv_n ( cram1_adv_n ), .cram1_cre ( cram1_cre ),
	.cram1_ce0_n ( cram1_ce0_n ), .cram1_ce1_n ( cram1_ce1_n ),
	.cram1_oe_n ( cram1_oe_n ), .cram1_we_n ( cram1_we_n ),
	.cram1_ub_n ( cram1_ub_n ), .cram1_lb_n ( cram1_lb_n )
);

// ============================================================ emu DDRAM
wire        ddram_clk;
wire        ddram_busy;
wire  [7:0] ddram_burstcnt;
wire [28:0] ddram_addr;
wire [63:0] ddram_dout;
wire        ddram_dout_ready;
wire        ddram_rd;
wire [63:0] ddram_din;
wire  [7:0] ddram_be;
wire        ddram_we;

pocket_ddram #(
	.W0_DDR   ( CFG_W0_DDR ),   .W0_PSRAM ( CFG_W0_PSRAM ), .W0_LOG2 ( CFG_W0_LOG2 ),
	.W1_DDR   ( CFG_W1_DDR ),   .W1_PSRAM ( CFG_W1_PSRAM ), .W1_LOG2 ( CFG_W1_LOG2 ),
	.W2_DDR   ( CFG_W2_DDR ),   .W2_PSRAM ( CFG_W2_PSRAM ), .W2_LOG2 ( CFG_W2_LOG2 ),
	.W3_DDR   ( CFG_W3_DDR ),   .W3_PSRAM ( CFG_W3_PSRAM ), .W3_LOG2 ( CFG_W3_LOG2 ),
	.SS_WIN   ( CFG_SS_WIN ),
	.MON_WR_BYTE ( CFG_SS_HDR_DDR )
) u_ddram (
	.clk            ( clk_sys ),
	.ddr_addr       ( ddram_addr ),
	.ddr_burstcnt   ( ddram_burstcnt ),
	.ddr_rd         ( ddram_rd ),
	.ddr_we         ( ddram_we ),
	.ddr_din        ( ddram_din ),
	.ddr_be         ( ddram_be ),
	.ddr_busy       ( ddram_busy ),
	.ddr_dout       ( ddram_dout ),
	.ddr_dout_ready ( ddram_dout_ready ),

	.ps_req   ( dd_req ),
	.ps_we    ( dd_we ),
	.ps_addr  ( dd_addr ),
	.ps_wdata ( dd_wdata ),
	.ps_be    ( dd_be ),
	.ps_ack   ( dd_ack ),
	.ps_rdata ( ps_rdata ),

	.mon_wr   ( mon_wr ),
	.mon_rd   ( mon_rd )
);

// ============================================================ audio PLL
wire clk_audio;
pocket_pll_audio u_pll_audio (
	.refclk   ( clk_74a ),
	.rst      ( 1'b0 ),
	.outclk_0 ( clk_audio ),
	.locked   ( )
);

// ============================================================ emu
wire        clk_vid, ce_pix;
wire  [7:0] vga_r, vga_g, vga_b;
wire        vga_hs, vga_vs, vga_de;
wire [15:0] audio_l, audio_r;
wire        audio_s;

// Autofire as in Main_MiSTer (Select held + button: 10 -> 15 -> 30 shots/s -> off),
// paced by the core's frames: one VSync edge per frame, brought into clk_74a.
// The settings (toggle + button + rate) go to the on-screen indicator, below.
wire af_frame;
wire       af1_tog, af2_tog;
wire [3:0] af1_key, af2_key;
wire [1:0] af1_lvl, af2_lvl;
synch_3 s_af_vs (.i(vga_vs), .o(), .clk(clk_74a), .rise(af_frame), .fall());
pocket_autofire u_af1 (.clk(clk_74a), .frame(af_frame), .key_in(cont1_key), .key_out(cont1_af),
                       .ev_tog(af1_tog), .ev_key(af1_key), .ev_lvl(af1_lvl));
pocket_autofire u_af2 (.clk(clk_74a), .frame(af_frame), .key_in(cont2_key), .key_out(cont2_af),
                       .ev_tog(af2_tog), .ev_key(af2_key), .ev_lvl(af2_lvl));
wire  [1:0] audio_mix;
wire  [3:0] adc_bus;

emu emu (
	.CLK_50M          ( clk_74a ),
	.RESET            ( emu_reset ),
	.POCKET_PLL_LOCKED( emu_pll_locked ),
	.HPS_BUS          ( hps_bus[CFG_HPS_BUS_W-1:0] ),   // 49 bits (recent sys) or 46 (old sys): bits 37:0 are the same

	.CLK_VIDEO        ( clk_vid ),
	.CE_PIXEL         ( ce_pix ),
	.VIDEO_ARX        ( ),
	.VIDEO_ARY        ( ),
	.VGA_R            ( vga_r ),
	.VGA_G            ( vga_g ),
	.VGA_B            ( vga_b ),
	.VGA_HS           ( vga_hs ),
	.VGA_VS           ( vga_vs ),
	.VGA_DE           ( vga_de ),
	.VGA_F1           ( ),
	.VGA_SL           ( ),
	.VGA_SCALER       ( ),
	.VGA_DISABLE      ( ),

	.HDMI_WIDTH       ( 12'd0 ),
	.HDMI_HEIGHT      ( 12'd0 ),
	.HDMI_FREEZE      ( ),
	.HDMI_BLACKOUT    ( ),
	.HDMI_BOB_DEINT   ( ),


	.LED_USER         ( ),
	.LED_POWER        ( ),
	.LED_DISK         ( ),
	.BUTTONS          ( ),

	.CLK_AUDIO        ( clk_audio ),
	.AUDIO_L          ( audio_l ),
	.AUDIO_R          ( audio_r ),
	.AUDIO_S          ( audio_s ),
	.AUDIO_MIX        ( audio_mix ),

	.ADC_BUS          ( adc_bus ),

	.SD_SCK           ( ),
	.SD_MOSI          ( ),
	.SD_MISO          ( 1'b1 ),
	.SD_CS            ( ),
	.SD_CD            ( 1'b1 ),

	.DDRAM_CLK        ( ddram_clk ),
	.DDRAM_BUSY       ( ddram_busy ),
	.DDRAM_BURSTCNT   ( ddram_burstcnt ),
	.DDRAM_ADDR       ( ddram_addr ),
	.DDRAM_DOUT       ( ddram_dout ),
	.DDRAM_DOUT_READY ( ddram_dout_ready ),
	.DDRAM_RD         ( ddram_rd ),
	.DDRAM_DIN        ( ddram_din ),
	.DDRAM_BE         ( ddram_be ),
	.DDRAM_WE         ( ddram_we ),


	.SDRAM_CLK        ( dram_clk ),
	.SDRAM_CKE        ( dram_cke ),
	.SDRAM_A          ( dram_a ),
	.SDRAM_BA         ( dram_ba ),
	.SDRAM_DQ         ( dram_dq ),
	.SDRAM_DQML       ( dram_dqm[0] ),
	.SDRAM_DQMH       ( dram_dqm[1] ),
	.SDRAM_nCS        ( ),
	.SDRAM_nCAS       ( dram_cas_n ),
	.SDRAM_nRAS       ( dram_ras_n ),
	.SDRAM_nWE        ( dram_we_n ),

	.UART_CTS         ( 1'b0 ),
	.UART_RTS         ( ),
	.UART_RXD         ( 1'b1 ),
	.UART_TXD         ( ),
	.UART_DTR         ( ),
	.UART_DSR         ( 1'b0 ),

	.USER_IN          ( 7'h7F ),
	.USER_OUT         ( ),

	.OSD_STATUS       ( 1'b0 )
);

// ============================================================ video
// scaler slot from the core's status bits (MiSTer rotation/flip)
wire [2:0] vid_slot = cfg_slot(cfg_status);

wire        pclk, pclk90;
wire [23:0] v_rgb;
wire        v_de, v_hs, v_vs;

// autofire indicator over the emu image (pocket_af_osd.sv); image size and slot
// rotations come from pocket.json, passed as macros in the project .qsf
wire  [7:0] o_r, o_g, o_b;
pocket_af_osd #(.W(`POCKET_VID_W), .H(`POCKET_VID_H), .QT(`POCKET_SLOT_QT), .VS_POL(CFG_VS_POL)) u_af_osd (
	.clk     ( clk_vid ),
	.ce_pix  ( ce_pix ),
	.de      ( vga_de ),
	.vs      ( vga_vs ),
	.slot    ( vid_slot ),
	.r_in    ( vga_r ),
	.g_in    ( vga_g ),
	.b_in    ( vga_b ),
	.r_out   ( o_r ),
	.g_out   ( o_g ),
	.b_out   ( o_b ),
	.ev1_tog ( af1_tog ),
	.ev1_key ( af1_key ),
	.ev1_lvl ( af1_lvl ),
	.ev2_tog ( af2_tog ),
	.ev2_key ( af2_key ),
	.ev2_lvl ( af2_lvl )
);

pocket_video #(.HS_POL(CFG_HS_POL), .VS_POL(CFG_VS_POL)) u_video (
	.clk    ( clk_vid ),
	.ce_pix ( ce_pix ),
	.r      ( o_r ),
	.g      ( o_g ),
	.b      ( o_b ),
	.hs     ( vga_hs ),
	.vs     ( vga_vs ),
	.de     ( vga_de ),
	.slot   ( vid_slot ),
	.rgb_o  ( v_rgb ),
	.de_o   ( v_de ),
	.hs_o   ( v_hs ),
	.vs_o   ( v_vs ),
	.pclk   ( pclk ),
	.pclk90 ( pclk90 )
);

assign video_rgb_clock    = pclk;
assign video_rgb_clock_90 = pclk90;
assign video_rgb          = v_rgb;
assign video_de           = v_de;
assign video_skip         = 1'b0;
assign video_hs           = v_hs;
assign video_vs           = v_vs;

// ============================================================ audio
// AUDIO_L/R sampled in the emu clock domain (as MiSTer's audio_out does, with
// a double register), then I2S 48 kHz.
// real registers (not a shift-register RAM: Quartus would put it in M10K)
(* altera_attribute = "-name AUTO_SHIFT_REGISTER_RECOGNITION OFF" *) reg [15:0] al1, ar1, al2, ar2;
(* altera_attribute = "-name AUTO_SHIFT_REGISTER_RECOGNITION OFF" *) reg        as1, as2;
(* altera_attribute = "-name AUTO_SHIFT_REGISTER_RECOGNITION OFF" *) reg  [1:0] am1, am2;
always @(posedge clk_sys) begin
	al1 <= audio_l; ar1 <= audio_r; as1 <= audio_s; am1 <= audio_mix;
	al2 <= al1;     ar2 <= ar1;     as2 <= as1;     am2 <= am1;
end
wire signed [15:0] sl = as2 ? al2 : {~al2[15], al2[14:0]};
wire signed [15:0] sr = as2 ? ar2 : {~ar2[15], ar2[14:0]};
// MiSTer AUDIO_MIX: 0 none, 1 25%, 2 50%, 3 mono
// (a bit select is unsigned in Verilog: $signed is required)
wire signed [16:0] msum  = sl + sr;
wire signed [15:0] mmono = $signed(msum[16:1]);
wire signed [17:0] l3    = $signed(sl) * 3 + $signed(sr);
wire signed [17:0] r3    = $signed(sr) * 3 + $signed(sl);
wire signed [16:0] l2    = sl + mmono;
wire signed [16:0] r2    = sr + mmono;
reg  signed [15:0] ml, mr;
always @(posedge clk_sys) begin
	case (am2)
		2'd0:    begin ml <= sl;               mr <= sr;               end
		2'd1:    begin ml <= $signed(l3[17:2]); mr <= $signed(r3[17:2]); end
		2'd2:    begin ml <= $signed(l2[16:1]); mr <= $signed(r2[16:1]); end
		default: begin ml <= mmono;            mr <= mmono;            end
	endcase
end

sound_i2s #(
	.CHANNEL_WIDTH ( 16 ),
	.SIGNED_INPUT  ( 1 )
) u_i2s (
	.clk_74a    ( clk_74a ),
	.clk_audio  ( clk_sys ),
	.audio_l    ( ml ),
	.audio_r    ( mr ),
	.audio_mclk ( audio_mclk ),
	.audio_lrck ( audio_lrck ),
	.audio_dac  ( audio_dac )
);

endmodule
