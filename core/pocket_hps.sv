// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) Umberto Parisi (rmonic79).
//
// pocket_hps — plays the role of the MiSTer HPS on emu's HPS_BUS, so
// hps_io.sv stays the original one and the core does not know it is on the Pocket.
//
// Protocol (MiSTer hps_io.sv + sys_top.v):
//   HPS_BUS[35] fp_enable  -> file commands (FIO)
//   HPS_BUS[34] io_enable  -> user io commands (UIO)
//   HPS_BUS[33] io_strobe  -> 1-cycle pulse for each 16-bit word
//   HPS_BUS[31:16] io_din  -> the word
//   HPS_BUS[37] ioctl_wait <- from the core: while it is high the next word
//                             is not sent (like io_ack in sys_top)
//   HPS_BUS[36] clk_sys    <- the clock of this module
// First word of a command = code; dropping the enable ends the command.
//
// Sequences replicated from Main_MiSTer:
//   status  : UIO 0x1E + 8 words (status[127:0])
//   joystick: UIO 0x02/0x03 + 2 words
//   file    : FIO 0x55 index ; FIO 0x53 0x00FF (download on) ;
//             FIO 0x54 data... ; FIO 0x53 0x0000 (download off)
// Initial load, in MRA order: index MOD_INDEX (mod byte, before the ROMs),
// index ROM_INDEX (the .rom file from PSRAM), index 254 (DIP). Then, at run
// time: status/joystick when they change, DIP (index 254) when they change,
// as the MiSTer menu does.
//
// Inputs from the clk_74a domain: quasi-static buses accompanied by a toggle.
// The bus changes on the same edge as the toggle and then stays still for much
// longer than the synchronisation time (bridge writes >= ~1 us apart,
// controllers read every ~880 us): sampling it 2 cycles after seeing the
// synchronised toggle is safe.

module pocket_hps #(
	parameter [15:0] ROM_INDEX  = 16'd0,
	parameter [15:0] MOD_INDEX  = 16'd1,
	parameter integer MOD_LEN   = 0,          // mod bytes (0 = do not send)
	parameter integer DIP_LEN   = 8,          // DIP bytes (0 = do not send)
	parameter [22:0] STAGE_W    = 23'h400000, // PSRAM word (32 bits) where the .rom starts
	parameter integer MIN_GAP   = 16,         // minimum cycles between two strobes
	parameter integer PULSE_CYC = 2000000     // duration of the pulse bits in the status
)(
	input             clk,

	// HPS_BUS side
	output reg        io_strobe = 0,
	output reg        io_uio = 0,
	output reg        io_fpga = 0,
	output reg [15:0] io_din = 0,
	input             io_wait,

	// from the clk_74a domain (quasi-static + toggle)
	input             cfg_tog,
	input     [127:0] status_in,
	input      [63:0] dip_in,
	input      [31:0] mod_in,
	input             pulse_tog,
	input     [127:0] pulse_in,
	input             joy_tog,
	input      [31:0] joy0_in,
	input      [31:0] joy1_in,
	input             start_tog,
	input      [31:0] rom_size_in,

	// .rom read from PSRAM (pocket_psram port, same clock)
	output reg        ps_req = 0,
	output reg [22:0] ps_addr,
	input             ps_ack,
	input      [31:0] ps_rdata,

	output reg        loading = 0,   // high during the initial load
	output reg        loaded  = 0
);

// ---------------------------------------------------------------- CDC
reg [2:0] cfg_s, pulse_s, joy_s, start_s;
reg [1:0] cfg_d, pulse_d, joy_d, start_d;     // sampling delay
always @(posedge clk) begin
	cfg_s   <= {cfg_s[1:0],   cfg_tog};
	pulse_s <= {pulse_s[1:0], pulse_tog};
	joy_s   <= {joy_s[1:0],   joy_tog};
	start_s <= {start_s[1:0], start_tog};
	cfg_d   <= {cfg_d[0],   cfg_s[2]   ^ cfg_s[1]};
	pulse_d <= {pulse_d[0], pulse_s[2] ^ pulse_s[1]};
	joy_d   <= {joy_d[0],   joy_s[2]   ^ joy_s[1]};
	start_d <= {start_d[0], start_s[2] ^ start_s[1]};
end

reg [127:0] status_q = 0;
reg  [63:0] dip_q = 0;
reg  [31:0] mod_q = 0;
reg [127:0] pulse_q = 0;
reg  [31:0] joy0_q = 0, joy1_q = 0;
reg  [31:0] rom_size_q = 0;
reg         start_pend = 0;
reg         pulse_on = 0;
reg  [31:0] pulse_cnt = 0;

always @(posedge clk) begin
	// also when the load starts: if the Pocket never wrote the registers,
	// the pocket_bridge defaults apply (stable since power-up)
	if (cfg_d[1] || start_d[1]) begin status_q <= status_in; dip_q <= dip_in; mod_q <= mod_in; end
	if (joy_d[1])   begin joy0_q <= joy0_in; joy1_q <= joy1_in; end
	if (pulse_d[1]) begin pulse_q <= pulse_in; pulse_on <= 1; pulse_cnt <= PULSE_CYC; end
	else if (pulse_cnt != 0) pulse_cnt <= pulse_cnt - 1;
	else pulse_on <= 0;
	if (start_d[1]) begin rom_size_q <= rom_size_in; start_pend <= 1; end
	else if (loading) start_pend <= 0;
end

wire [127:0] status_out = status_q | (pulse_on ? pulse_q : 128'd0);

// ---------------------------------------------------------------- strobe
// a word is sent only if MIN_GAP cycles have passed since the last one and
// ioctl_wait is low (the same constraint that io_ack imposes on the HPS).
reg  [7:0] gap = 0;
reg        wait_r = 0;
always @(posedge clk) wait_r <= io_wait;
wire can_strobe = (gap == 0) && !wait_r;

// ---------------------------------------------------------------- sequences
localparam J_NONE   = 3'd0;
localparam J_STATUS = 3'd1;
localparam J_JOY0   = 3'd2;
localparam J_JOY1   = 3'd3;
localparam J_FILE   = 3'd4;

localparam F_MOD = 2'd0;
localparam F_ROM = 2'd1;
localparam F_DIP = 2'd2;

localparam P_IDLE  = 3'd0;
localparam P_EN    = 3'd1;   // enable high, first word on the next cycle
localparam P_WORD  = 3'd2;   // sending words
localparam P_FETCH = 3'd3;   // PSRAM read (.rom data only)
localparam P_END   = 3'd4;   // enable low and pause
localparam P_NEXT  = 3'd5;   // decides the next step

reg  [2:0] job = J_NONE;
reg  [1:0] fsrc;            // source of the current file
reg  [1:0] fstep;           // 0 index, 1 start, 2 data, 3 stop
reg  [2:0] ph = P_IDLE;
reg [23:0] k;               // current word of the command (0 = code)
reg [23:0] nwords;          // total words of the command (code included)
reg  [7:0] endcnt;
reg [31:0] rbuf;
reg        rbuf_ok;
reg  [1:0] load_step;       // 0 mod, 1 rom, 2 dip, 3 done

reg [127:0] status_sent = 0;
reg  [31:0] joy0_sent = 0, joy1_sent = 0;
reg  [63:0] dip_sent = 0;
reg         dip_valid = 0;   // dip_sent valid (sent at least once)

// "anything to send?" computed in a register one cycle earlier: the 128-bit
// status compare (and the joystick/DIP ones) stays out of the job-selection path
// in P_IDLE (timing at 96 MHz on the Pocket). The *_sent values change only in
// P_EN, and P_IDLE comes at least 5 cycles later (P_WORD x3, P_END, P_NEXT): in
// P_IDLE the flag compares the live value of the previous cycle with the current
// *_sent, so a change is seen just one cycle later. The snapshot in P_EN is
// taken from the live value.
reg st_dirty = 0, j0_dirty = 0, j1_dirty = 0, dip_dirty = 0;
always @(posedge clk) begin
	st_dirty  <= (status_out != status_sent);
	j0_dirty  <= (joy0_q != joy0_sent);
	j1_dirty  <= (joy1_q != joy1_sent);
	dip_dirty <= !dip_valid || (dip_q != dip_sent);
end

// k == 0 and k == 1 are kept in registers alongside k (k is written only in
// P_EN, to 0, and in P_WORD, +1): no 24-bit compares in the word selection.
reg k0 = 0, k1 = 0;

wire [23:0] rom_words = (rom_size_q[24:0] + 25'd1) >> 1;   // 16-bit words
localparam [23:0] MOD_WORDS = (MOD_LEN + 1) / 2;
localparam [23:0] DIP_WORDS = (DIP_LEN + 1) / 2;

// word k of the current command. status/joystick/DIP come from the copy
// snapshotted at the start of the command (*_sent), never from the live value:
// a change in the middle of a command must not produce mixed words.
reg [15:0] word_k;
always @(*) begin
	word_k = 16'd0;
	case (job)
		J_STATUS: case (k[3:0])
			4'd0: word_k = 16'h001E;
			4'd1: word_k = status_sent[15:0];
			4'd2: word_k = status_sent[31:16];
			4'd3: word_k = status_sent[47:32];
			4'd4: word_k = status_sent[63:48];
			4'd5: word_k = status_sent[79:64];
			4'd6: word_k = status_sent[95:80];
			4'd7: word_k = status_sent[111:96];
			default: word_k = status_sent[127:112];
		endcase
		J_JOY0: word_k = k0 ? 16'h0002 : k1 ? joy0_sent[15:0] : joy0_sent[31:16];
		J_JOY1: word_k = k0 ? 16'h0003 : k1 ? joy1_sent[15:0] : joy1_sent[31:16];
		J_FILE: case (fstep)
			2'd0: word_k = k0 ? 16'h0055 :
			               (fsrc == F_MOD) ? MOD_INDEX : (fsrc == F_ROM) ? ROM_INDEX : 16'd254;
			2'd1: word_k = k0 ? 16'h0053 : 16'h00FF;
			2'd3: word_k = k0 ? 16'h0053 : 16'h0000;
			default: begin
				if (k0) word_k = 16'h0054;
				else case (fsrc)
					F_MOD: word_k = k1 ? mod_q[15:0] : mod_q[31:16];
					F_DIP: case (k[2:0])
						3'd1: word_k = dip_sent[15:0];
						3'd2: word_k = dip_sent[31:16];
						3'd3: word_k = dip_sent[47:32];
						default: word_k = dip_sent[63:48];
					endcase
					default: word_k = k[0] ? rbuf[15:0] : rbuf[31:16];   // k=1 -> low half
				endcase
			end
		endcase
		default: ;
	endcase
end

// number of words of the current command (code included)
reg [23:0] words_of;
always @(*) begin
	case (job)
		J_STATUS: words_of = 24'd9;
		J_JOY0,
		J_JOY1:   words_of = 24'd3;
		default:  case (fstep)
			2'd2: words_of = 24'd1 + ((fsrc == F_MOD) ? MOD_WORDS : (fsrc == F_ROM) ? rom_words : DIP_WORDS);
			default: words_of = 24'd2;
		endcase
	endcase
end

always @(posedge clk) begin
	io_strobe <= 0;
	if (gap != 0) gap <= gap - 8'd1;
	// POCKET: a new start (the Pocket rewrote the .rom slot and sent Reset Exit
	// again, without reloading the bitstream) repeats the full load (status, mod,
	// .rom, DIP), as the first time.
	if (start_d[1]) loaded <= 0;

	case (ph)
		P_IDLE: begin
			// choice of the next job
			if (start_pend && !loaded && !loading) begin
				loading   <= 1;
				load_step <= (MOD_LEN != 0) ? 2'd0 : 2'd1;
				job       <= J_STATUS;      // status first, as at MiSTer start-up
				ph        <= P_EN;
			end
			else if (loading) begin
				job   <= J_FILE;
				fstep <= 2'd0;
				fsrc  <= (load_step == 2'd0) ? F_MOD : (load_step == 2'd1) ? F_ROM : F_DIP;
				ph    <= P_EN;
			end
			else if (st_dirty) begin job <= J_STATUS; ph <= P_EN; end
			else if (j0_dirty) begin job <= J_JOY0;   ph <= P_EN; end
			else if (j1_dirty) begin job <= J_JOY1;   ph <= P_EN; end
			else if (loaded && DIP_LEN != 0 && dip_dirty) begin
				job <= J_FILE; fstep <= 2'd0; fsrc <= F_DIP; ph <= P_EN;
			end
		end

		P_EN: begin
			if (job == J_FILE) io_fpga <= 1; else io_uio <= 1;
			k       <= 0;
			k0      <= 1;
			k1      <= 0;
			nwords  <= words_of;
			rbuf_ok <= 0;
			// values snapshotted at the start of the command
			if (job == J_STATUS) status_sent <= status_out;
			if (job == J_JOY0)   joy0_sent   <= joy0_q;
			if (job == J_JOY1)   joy1_sent   <= joy1_q;
			if (job == J_FILE && fsrc == F_DIP && fstep == 2'd2) begin dip_sent <= dip_q; dip_valid <= 1; end
			ph <= P_WORD;
		end

		P_WORD: begin
			if (k == nwords) begin
				ph <= P_END;
			end
			else if (job == J_FILE && fstep == 2'd2 && fsrc == F_ROM && !k0 && k[0] && !rbuf_ok) begin
				// the 32-bit word (k-1)/2 of the .rom is needed
				ph <= P_FETCH;
			end
			else if (can_strobe) begin
				io_din    <= word_k;
				io_strobe <= 1;
				gap       <= MIN_GAP[7:0];
				if (job == J_FILE && fstep == 2'd2 && fsrc == F_ROM && !k0 && !k[0]) rbuf_ok <= 0;
				k  <= k + 24'd1;
				k0 <= 0;
				k1 <= k0;
			end
		end

		P_FETCH: begin
			if (!ps_req) begin
				ps_req  <= 1;
				ps_addr <= STAGE_W + k[23:1];   // odd k: (k-1)/2 = k>>1
			end
			else if (ps_ack) begin
				ps_req  <= 0;
				rbuf    <= ps_rdata;
				rbuf_ok <= 1;
				ph      <= P_WORD;
			end
		end

		P_END: begin
			io_uio  <= 0;
			io_fpga <= 0;
			endcnt  <= MIN_GAP[7:0];
			ph      <= P_NEXT;
		end

		P_NEXT: begin
			if (endcnt != 0) endcnt <= endcnt - 8'd1;
			else begin
				ph <= P_IDLE;
				if (job == J_FILE && fstep != 2'd3) begin
					fstep <= fstep + 2'd1;
					ph    <= P_EN;
				end
				else if (job == J_FILE && loading) begin
					// file done: next step of the initial load
					if (load_step == 2'd2 || (load_step == 2'd1 && DIP_LEN == 0)) begin
						loading <= 0;
						loaded  <= 1;
					end
					else load_step <= load_step + 2'd1;
				end
			end
		end

		default: ph <= P_IDLE;
	endcase
end

endmodule
