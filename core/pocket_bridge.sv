// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) Umberto Parisi (rmonic79).
//
// pocket_bridge — everything the Pocket reads/writes on the bridge outside
// the 0xF8xxxxxx space (commands, handled by core_bridge_cmd).
//
// Map (bridge addresses):
//   0x0xxxxxxx  W   .rom file (data slot) -> PSRAM, staging area
//   0x2xxxxxxx  R/W savestate block       -> PSRAM, core savestate area
//   0x30000000  R/W status[31:0]    (0x04 [63:32], 0x08 [95:64], 0x0C [127:96])
//   0x30000010  R/W DIP[31:0]       (0x14 DIP[63:32])
//   0x30000020  R/W mod byte (MRA index 1), written by the instance JSON
//   0x30000040  W   pulse on status[31:0] (0x44, 0x48, 0x4C the other words):
//                   the written bits stay high for ~PULSE and then return to 0
//                   (the "R"/"T" entries of the MiSTer CONF_STR, e.g. Reset)
//
// Byte order: with bridge_endian_little = 0 the first byte of the file is in
// [31:24]. In PSRAM the 32-bit word is kept little endian (byte 0 in [7:0]),
// i.e. identical to the file image / the MiSTer DDR3 image: the 4 bytes are
// swapped on both writes and reads.
//
// Savestate (Pocket commands 00A0/00A4), same scheme as Main_MiSTer:
//   save : pulse on status bit SS_SAVE_BIT -> the core saves into slot 0 and,
//          as its last step, rewrites the region header (mon_wr_tog); at that
//          point the block in PSRAM is complete and the Pocket reads it.
//   load : the Pocket has already written the block; pulse on SS_LOAD_BIT ->
//          the core reads the area back (mon_rd_tog); done when there have
//          been no more reads for SS_QUIET cycles.

module pocket_bridge #(
	parameter [24:0]  STAGE_BYTE  = 25'h1000000,  // PSRAM byte where the .rom staging starts
	parameter [24:0]  SS_BYTE     = 25'h0800010,  // PSRAM byte of the savestate block
	parameter [31:0]  SS_SIZE     = 32'h00038000, // savestate block size in bytes
	parameter         SS_ENABLE   = 1,
	parameter integer SS_SAVE_BIT = 110,
	parameter integer SS_LOAD_BIT = 111,
	parameter integer SS_QUIET    = 1048576,      // clk_74a cycles without reads = load finished
	parameter integer SS_TIMEOUT  = 268435456,    // ~3.6 s at 74.25 MHz
	parameter [127:0] STATUS_DEFAULT = 128'd0,
	parameter [63:0]  DIP_DEFAULT    = 64'h000000000000FFFF,
	parameter [31:0]  MOD_DEFAULT    = 32'd0
)(
	input             clk,            // clk_74a

	input      [31:0] bridge_addr,
	input             bridge_rd,
	input             bridge_wr,
	input      [31:0] bridge_wr_data,
	output reg [31:0] rd_data = 0,    // savestate (0x2xxxxxxx): data of the PREVIOUS read (slow PSRAM, prefetch)
	output reg [31:0] reg_rd_data = 0, // registers 0x300000xx: data of the CURRENT address, always ready
	output reg [25:0] stage_hi = 0,   // bytes written to staging: last address + 4 = .rom length as seen by the bridge
	input             stage_clr,      // new write request for the .rom slot: restart from 0

	// registers to pocket_hps (quasi-static + toggle)
	output reg [127:0] status = STATUS_DEFAULT,
	output reg  [63:0] dip    = DIP_DEFAULT,
	output reg  [31:0] mod    = MOD_DEFAULT,
	output reg         cfg_tog = 0,
	output reg [127:0] pulse  = 0,
	output reg         pulse_tog = 0,

	// savestate (core_bridge_cmd)
	input             savestate_start,
	output reg        savestate_start_ack = 0,
	output reg        savestate_start_busy = 0,
	output reg        savestate_start_ok = 0,
	output reg        savestate_start_err = 0,
	input             savestate_load,
	output reg        savestate_load_ack = 0,
	output reg        savestate_load_busy = 0,
	output reg        savestate_load_ok = 0,
	output reg        savestate_load_err = 0,

	// DDR monitor (ps_clk domain, toggle)
	input             mon_wr_tog,
	input             mon_rd_tog,

	// PSRAM port (ps_clk domain)
	input             ps_clk,
	output reg        ps_req = 0,
	output reg        ps_we,
	output reg [22:0] ps_addr,
	output reg [31:0] ps_wdata,
	output      [3:0] ps_be,
	input             ps_ack,
	input      [31:0] ps_rdata
);

assign ps_be = 4'hF;

function [31:0] bswap(input [31:0] d);
	bswap = {d[7:0], d[15:8], d[23:16], d[31:24]};
endfunction

// ======================================================= clk_74a: writes
reg        fifo_wr = 0;
reg [63:0] fifo_d;             // {PSRAM word address (32), data (32)}
// 25 address bits: a .rom up to 32 MB - STAGE_BYTE. 24 bits (16 MB) are not
// enough: the BoogieWings .rom (19 MB) would wrap around and its last 2.2 MB
// would overwrite the start (68000 program).
wire [24:0] stage_b = STAGE_BYTE + bridge_addr[24:0];
wire [24:0] ss_b    = SS_BYTE + bridge_addr[24:0];
wire [25:0] wr_end  = {1'b0, bridge_addr[24:0]} + 26'd4;   // end of the written word

// savestate read: request to ps_clk
reg        rq_tog = 0;
reg [22:0] rq_addr;
wire       rk_tog;             // response toggle (ps_clk domain)
wire [31:0] rk_data;

reg [2:0] rk_s;
reg [2:0] mwr_s, mrd_s;
always @(posedge clk) begin
	rk_s  <= {rk_s[1:0], rk_tog};
	mwr_s <= {mwr_s[1:0], mon_wr_tog};
	mrd_s <= {mrd_s[1:0], mon_rd_tog};
end
wire rk_ev     = rk_s[2] ^ rk_s[1];      // rk_data stable for at least 2 cycles
wire mon_wr_ev = mwr_s[2] ^ mwr_s[1];
wire mon_rd_ev = mrd_s[2] ^ mrd_s[1];

// savestate
localparam SS_IDLE = 2'd0, SS_SAVE = 2'd1, SS_LOAD = 2'd2, SS_LOAD_RUN = 2'd3;
reg  [1:0] ss_st = SS_IDLE;
reg [31:0] ss_tmo;
reg [31:0] ss_quiet;
// request already served with an ack (cleared when the request goes low)
reg        st_start_done = 0, st_load_done = 0;
reg        ss_pulse_pend = 0;  // savestate pulse waiting for a free cycle
reg [127:0] ss_pulse_bits;

always @(posedge clk) begin
	fifo_wr <= 0;

	if (bridge_wr) begin
		casex (bridge_addr)
			32'h0xxxxxxx: begin
				fifo_d  <= {9'd0, stage_b[24:2], bswap(bridge_wr_data)};
				fifo_wr <= 1;
				if (wr_end > stage_hi) stage_hi <= wr_end;
			end
			32'h2xxxxxxx: begin
				fifo_d  <= {9'd0, ss_b[24:2], bswap(bridge_wr_data)};
				fifo_wr <= 1;
			end
			32'h300000xx: begin
				case (bridge_addr[7:0])
					8'h00: begin status[31:0]   <= bridge_wr_data; cfg_tog <= ~cfg_tog; end
					8'h04: begin status[63:32]  <= bridge_wr_data; cfg_tog <= ~cfg_tog; end
					8'h08: begin status[95:64]  <= bridge_wr_data; cfg_tog <= ~cfg_tog; end
					8'h0C: begin status[127:96] <= bridge_wr_data; cfg_tog <= ~cfg_tog; end
					8'h10: begin dip[31:0]      <= bridge_wr_data; cfg_tog <= ~cfg_tog; end
					8'h14: begin dip[63:32]     <= bridge_wr_data; cfg_tog <= ~cfg_tog; end
					8'h20: begin mod            <= bridge_wr_data; cfg_tog <= ~cfg_tog; end
					8'h40: begin pulse <= {96'd0, bridge_wr_data};        pulse_tog <= ~pulse_tog; end
					8'h44: begin pulse <= {64'd0, bridge_wr_data, 32'd0}; pulse_tog <= ~pulse_tog; end
					8'h48: begin pulse <= {32'd0, bridge_wr_data, 64'd0}; pulse_tog <= ~pulse_tog; end
					8'h4C: begin pulse <= {bridge_wr_data, 96'd0};        pulse_tog <= ~pulse_tog; end
					default: ;
				endcase
			end
			default: ;
		endcase
	end
	else if (ss_pulse_pend) begin
		// savestate pulse: on the first cycle without bridge writes
		pulse         <= ss_pulse_bits;
		pulse_tog     <= ~pulse_tog;
		ss_pulse_pend <= 0;
	end

	if (stage_clr) stage_hi <= 26'd0;

	// reads: the data must be presented before the next read
	if (bridge_rd) begin
		casex (bridge_addr)
			32'h2xxxxxxx: begin
				rq_addr <= ss_b[24:2];
				rq_tog  <= ~rq_tog;
			end
			default: ;
		endcase
	end
	// the savestate data arrives a few hundred ns after the request
	if (rk_ev) rd_data <= bswap(rk_data);

	// ---------------------------------------------------- savestate
	// One ack for EVERY request, even if it arrives while an operation is in
	// progress: core_bridge_cmd holds the request high until it sees the ack and
	// meanwhile does not answer any other command, so a lost ack would block it
	// forever ("host command ignored"). In the normal case (request while idle)
	// the ack is given by the SS_IDLE state below.
	if (!savestate_start) st_start_done <= 0;
	if (!savestate_load)  st_load_done  <= 0;
	savestate_start_ack <= 0;
	savestate_load_ack  <= 0;
	if (ss_st != SS_IDLE) begin
		// operation in progress: ack without starting another one; the status
		// stays that of the current operation
		if (savestate_start & ~st_start_done) begin savestate_start_ack <= 1; st_start_done <= 1; end
		if (savestate_load  & ~st_load_done)  begin savestate_load_ack  <= 1; st_load_done  <= 1; end
	end

	case (ss_st)
		SS_IDLE: begin
			if (savestate_start & ~st_start_done) begin
				st_start_done        <= 1;
				savestate_start_ack  <= 1;
				savestate_start_busy <= 1;
				savestate_start_ok   <= 0;
				savestate_start_err  <= 0;
				ss_pulse_bits        <= 128'd1 << SS_SAVE_BIT;
				ss_pulse_pend        <= 1;
				ss_tmo               <= SS_TIMEOUT;
				ss_st                <= SS_SAVE;
			end
			else if (savestate_load & ~st_load_done) begin
				st_load_done        <= 1;
				savestate_load_ack  <= 1;
				savestate_load_busy <= 1;
				savestate_load_ok   <= 0;
				savestate_load_err  <= 0;
				ss_pulse_bits       <= 128'd1 << SS_LOAD_BIT;
				ss_pulse_pend       <= 1;
				ss_tmo              <= SS_TIMEOUT;
				ss_st               <= SS_LOAD;
			end
		end
		SS_SAVE: begin
			ss_tmo <= ss_tmo - 1;
			if (mon_wr_ev) begin
				savestate_start_busy <= 0;
				savestate_start_ok   <= 1;
				ss_st <= SS_IDLE;
			end
			else if (ss_tmo == 0) begin
				savestate_start_busy <= 0;
				savestate_start_err  <= 1;
				ss_st <= SS_IDLE;
			end
		end
		SS_LOAD: begin
			// waiting for the first read of the savestate area
			ss_tmo <= ss_tmo - 1;
			if (mon_rd_ev) begin
				ss_quiet <= SS_QUIET;
				ss_st    <= SS_LOAD_RUN;
			end
			else if (ss_tmo == 0) begin
				savestate_load_busy <= 0;
				savestate_load_err  <= 1;
				ss_st <= SS_IDLE;
			end
		end
		SS_LOAD_RUN: begin
			if (mon_rd_ev) ss_quiet <= SS_QUIET;
			else if (ss_quiet != 0) ss_quiet <= ss_quiet - 1;
			else begin
				savestate_load_busy <= 0;
				savestate_load_ok   <= 1;
				ss_st <= SS_IDLE;
			end
		end
	endcase

	if (!SS_ENABLE) begin
		savestate_start_busy <= 0; savestate_start_ok <= 0; savestate_start_err <= 0;
		savestate_load_busy  <= 0; savestate_load_ok  <= 0; savestate_load_err  <= 0;
		ss_st <= SS_IDLE;
	end
end

// ======================================================= registers: read by address
// POCKET: the APF bridge (io_bridge_peripheral) samples bridge_rd_data 4 cycles
// after latching the address, BEFORE the bridge_rd pulse; the Analogue template
// presents the data as a function of the address. With the data updated only on
// bridge_rd the Pocket would read back the value of the previous read: during the
// interact menu setup (it writes the defaults and reads them back) this gives
// "Load error in interact" + "Error in core setup".
always @(posedge clk) begin
	case (bridge_addr[7:0])
		8'h00: reg_rd_data <= status[31:0];
		8'h04: reg_rd_data <= status[63:32];
		8'h08: reg_rd_data <= status[95:64];
		8'h0C: reg_rd_data <= status[127:96];
		8'h10: reg_rd_data <= dip[31:0];
		8'h14: reg_rd_data <= dip[63:32];
		8'h20: reg_rd_data <= mod;
		default: reg_rd_data <= 32'd0;
	endcase
end

// ======================================================= write FIFO
wire        f_empty;
wire [63:0] f_q;
reg         f_rd = 0;

dcfifo f_wr (
	.data    (fifo_d),
	.wrclk   (clk),
	.wrreq   (fifo_wr),
	.rdclk   (ps_clk),
	.rdreq   (f_rd),
	.q       (f_q),
	.rdempty (f_empty),
	.aclr    (1'b0),
	.eccstatus(),
	.rdfull  (),
	.rdusedw (),
	.wrempty (),
	.wrfull  (),
	.wrusedw ()
);
defparam f_wr.intended_device_family = "Cyclone V",
         f_wr.lpm_numwords = 16, f_wr.lpm_widthu = 4, f_wr.lpm_width = 64,
         f_wr.lpm_showahead = "ON", f_wr.lpm_type = "dcfifo",
         f_wr.overflow_checking = "ON", f_wr.underflow_checking = "ON",
         f_wr.rdsync_delaypipe = 4, f_wr.wrsync_delaypipe = 4,
         f_wr.use_eab = "ON",
         f_wr.ram_block_type = "MLAB";   // 16x64: in MLAB, no M10K needed

// ======================================================= ps_clk: PSRAM port
reg [2:0] rq_s;
reg       rq_pend = 0;
reg [22:0] rq_addr_q;
reg       rk_tog_r = 0;
reg [31:0] rk_data_r = 0;
assign rk_tog  = rk_tog_r;
assign rk_data = rk_data_r;

localparam P_IDLE = 2'd0, P_WR = 2'd1, P_RD = 2'd2;
reg [1:0] pst = P_IDLE;

always @(posedge ps_clk) begin
	rq_s <= {rq_s[1:0], rq_tog};
	f_rd <= 0;
	if (rq_s[2] ^ rq_s[1]) begin
		rq_pend   <= 1;
		rq_addr_q <= rq_addr;     // stable for at least 2 cycles
	end

	case (pst)
		P_IDLE: begin
			// queued writes go before reads
			if (!f_empty) begin
				ps_req   <= 1;
				ps_we    <= 1;
				ps_addr  <= f_q[54:32];
				ps_wdata <= f_q[31:0];
				f_rd     <= 1;
				pst      <= P_WR;
			end
			else if (rq_pend) begin
				ps_req  <= 1;
				ps_we   <= 0;
				ps_addr <= rq_addr_q;
				rq_pend <= 0;
				pst     <= P_RD;
			end
		end
		P_WR: if (ps_ack) begin
			ps_req <= 0;
			pst    <= P_IDLE;
		end
		P_RD: if (ps_ack) begin
			ps_req    <= 0;
			rk_data_r <= ps_rdata;
			rk_tog_r  <= ~rk_tog_r;
			pst       <= P_IDLE;
		end
		default: pst <= P_IDLE;
	endcase
end

endmodule
