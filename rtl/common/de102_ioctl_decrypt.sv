//
// de102_ioctl_decrypt.sv
// Transparent wrapper on the ioctl stream that decrypts the Boogie Wings
// DE102 MAIN 68K ROM DURING THE DOWNLOAD, producing the 2 views (op + data)
// already decrypted in SDRAM. The CPU bridge therefore reads an already
// decrypted ROM: dual view, op@0x000000 + data@0x1130000.
//
// The MRA loads the ENCRYPTED main ROM TWICE:
//   OP range   (ioctl 0x000000-0x0FFFFF)   -> opcode decrypt (select_xor=0x18)
//   DATA range (ioctl 0x1130000-0x122FFFF) -> data decrypt   (select_xor=0x00)
// Each range is 1->1 (no double write): the wrapper applies the right
// decryption and the inverse remap of the address scramble.
//
// ADDRESS SCRAMBLE (deco102): the source word index s = src_index(i) is AFFINE
//   over GF(2): s = M*i ^ 0x42BA. The inverse is affine too: i = Minv*(s ^ 0x42BA),
//   purely combinational (bit XORs, no BRAM). The Minv columns are computed
//   offline (GF(2) inverse of M). The download delivers the physical word at
//   linear index s -> decrypt(raw) is written at logical index i = inv_scramble(s).
//
// DATA DECRYPT (deco102): dout = xor_lut(j_xor) ^ bitswap(j_bs, din), with
//   j_bs/j_xor computed from i (logical word) and select_xor (op/data).
//
// Purely combinational -> no latency, no BRAM, everything else passes through.
//

module de102_ioctl_decrypt
(
	input  wire        clk,
	input  wire [26:0] ioctl_addr_in,
	input  wire [15:0] ioctl_dout_in,
	input  wire        ioctl_wr_in,
	input  wire [15:0] ioctl_index_in,
	input  wire        ioctl_download_in,

	output wire [26:0] ioctl_addr_out,
	output wire [15:0] ioctl_dout_out,
	output wire        ioctl_wr_out,
	output wire [15:0] ioctl_index_out,
	output wire        ioctl_download_out,

	// Exposed for the download PRIORITY mux in Template.sv, used instead of a
	// serial de102 -> deco56 cascade (timing).
	output wire        remap_out
);

	localparam [26:0] OP_BASE   = 27'h0000000;
	localparam [26:0] OP_END    = 27'h0100000;   // 1 MB
	localparam [26:0] DATA_BASE = 27'h1130000;
	localparam [26:0] DATA_END  = 27'h1230000;   // 1 MB

	wire is_rom_dl = ioctl_download_in & (ioctl_index_in == 16'd0);
	wire in_op   = is_rom_dl && (ioctl_addr_in >= OP_BASE)   && (ioctl_addr_in < OP_END);
	wire in_data = is_rom_dl && (ioctl_addr_in >= DATA_BASE) && (ioctl_addr_in < DATA_END);
	wire is_main = in_op | in_data;

	wire [26:0] cur_base = in_op ? OP_BASE : DATA_BASE;
	wire        byte_lo  = ioctl_addr_in[0];

	// physical word index s (19-bit) relative to the base
	wire [18:0] s = (ioctl_addr_in - cur_base) >> 1;

	// ── Inverse affine scramble: i = Minv*(s ^ 0x42BA) ──────────────────────
	// Minv columns (bit s[b] -> contribution to i), computed offline (GF(2)).
	wire [18:0] x = s ^ 19'h042BA;
	wire [18:0] i_word =
		({19{x[ 0]}} & 19'h0f9b0) ^ ({19{x[ 1]}} & 19'h04080) ^
		({19{x[ 2]}} & 19'h00008) ^ ({19{x[ 3]}} & 19'h02000) ^
		({19{x[ 4]}} & 19'h05000) ^ ({19{x[ 5]}} & 19'h05880) ^
		({19{x[ 6]}} & 19'h00110) ^ ({19{x[ 7]}} & 19'h0d990) ^
		({19{x[ 8]}} & 19'h00804) ^ ({19{x[ 9]}} & 19'h00202) ^
		({19{x[10]}} & 19'h02040) ^ ({19{x[11]}} & 19'h08100) ^
		({19{x[12]}} & 19'h01202) ^ ({19{x[13]}} & 19'h0fdd1) ^
		({19{x[14]}} & 19'h06062) ^ ({19{x[15]}} & 19'h0d5a0) ^
		({19{x[16]}} & 19'h10000) ^ ({19{x[17]}} & 19'h20000) ^
		({19{x[18]}} & 19'h40000);

	// ── DE102 data decrypt (on i_word) ──────────────────────────────────────
	// CPU addr = {i_word, 1'b0}; the decryption uses i = addr[19:1] = i_word.
	localparam [15:0] OP_SEL_XOR   = 16'h0018;
	localparam [15:0] DATA_SEL_XOR = 16'h0000;
	wire [15:0] select_xor = in_op ? OP_SEL_XOR : DATA_SEL_XOR;

	function [15:0] xor_lut(input [3:0] idx);
		case (idx)
			4'h0: xor_lut = 16'hb52c; 4'h1: xor_lut = 16'h2458;
			4'h2: xor_lut = 16'h139a; 4'h3: xor_lut = 16'hc998;
			4'h4: xor_lut = 16'hce8e; 4'h5: xor_lut = 16'h5144;
			4'h6: xor_lut = 16'h0429; 4'h7: xor_lut = 16'haad4;
			4'h8: xor_lut = 16'ha331; 4'h9: xor_lut = 16'h3645;
			4'ha: xor_lut = 16'h69a3; 4'hb: xor_lut = 16'hac64;
			4'hc: xor_lut = 16'h1a53; 4'hd: xor_lut = 16'h5083;
			4'he: xor_lut = 16'h4dea; 4'hf: xor_lut = 16'hd237;
		endcase
	endfunction

	function [15:0] bs_apply(input [3:0] tbl, input [15:0] d);
		case (tbl)
			4'h0: bs_apply = {d[12],d[ 8],d[13],d[11],d[14],d[10],d[15],d[ 9], d[ 3],d[ 2],d[ 1],d[ 0],d[ 4],d[ 5],d[ 6],d[ 7]};
			4'h1: bs_apply = {d[10],d[11],d[14],d[12],d[15],d[13],d[ 8],d[ 9], d[ 6],d[ 7],d[ 5],d[ 3],d[ 0],d[ 4],d[ 2],d[ 1]};
			4'h2: bs_apply = {d[14],d[13],d[15],d[ 9],d[ 8],d[12],d[11],d[10], d[ 7],d[ 4],d[ 1],d[ 5],d[ 6],d[ 0],d[ 3],d[ 2]};
			4'h3: bs_apply = {d[15],d[14],d[ 8],d[ 9],d[10],d[11],d[13],d[12], d[ 1],d[ 2],d[ 7],d[ 3],d[ 4],d[ 6],d[ 0],d[ 5]};
			4'h4: bs_apply = {d[10],d[ 9],d[13],d[14],d[15],d[ 8],d[12],d[11], d[ 5],d[ 2],d[ 1],d[ 0],d[ 3],d[ 4],d[ 7],d[ 6]};
			4'h5: bs_apply = {d[ 8],d[ 9],d[15],d[14],d[10],d[11],d[13],d[12], d[ 0],d[ 6],d[ 5],d[ 4],d[ 1],d[ 2],d[ 3],d[ 7]};
			4'h6: bs_apply = {d[14],d[ 8],d[15],d[ 9],d[10],d[11],d[13],d[12], d[ 4],d[ 5],d[ 3],d[ 0],d[ 2],d[ 7],d[ 6],d[ 1]};
			4'h7: bs_apply = {d[13],d[11],d[12],d[10],d[15],d[ 9],d[14],d[ 8], d[ 6],d[ 0],d[ 7],d[ 5],d[ 1],d[ 4],d[ 3],d[ 2]};
			4'h8: bs_apply = {d[12],d[11],d[13],d[10],d[ 9],d[ 8],d[14],d[15], d[ 0],d[ 2],d[ 4],d[ 6],d[ 7],d[ 5],d[ 3],d[ 1]};
			4'h9: bs_apply = {d[15],d[13],d[ 9],d[ 8],d[10],d[11],d[12],d[14], d[ 2],d[ 1],d[ 0],d[ 7],d[ 6],d[ 5],d[ 4],d[ 3]};
			4'ha: bs_apply = {d[13],d[ 8],d[ 9],d[10],d[11],d[12],d[15],d[14], d[ 6],d[ 0],d[ 1],d[ 2],d[ 3],d[ 7],d[ 4],d[ 5]};
			4'hb: bs_apply = {d[12],d[11],d[10],d[ 8],d[ 9],d[13],d[14],d[15], d[ 6],d[ 5],d[ 4],d[ 0],d[ 7],d[ 1],d[ 2],d[ 3]};
			4'hc: bs_apply = {d[12],d[15],d[ 8],d[13],d[ 9],d[11],d[14],d[10], d[ 6],d[ 5],d[ 4],d[ 3],d[ 2],d[ 1],d[ 0],d[ 7]};
			4'hd: bs_apply = {d[11],d[12],d[13],d[14],d[15],d[ 8],d[ 9],d[10], d[ 4],d[ 5],d[ 7],d[ 1],d[ 6],d[ 3],d[ 2],d[ 0]};
			4'he: bs_apply = {d[13],d[ 8],d[12],d[14],d[11],d[15],d[10],d[ 9], d[ 7],d[ 6],d[ 5],d[ 4],d[ 3],d[ 2],d[ 1],d[ 0]};
			4'hf: bs_apply = {d[15],d[14],d[13],d[12],d[11],d[10],d[ 9],d[ 8], d[ 0],d[ 6],d[ 7],d[ 4],d[ 3],d[ 2],d[ 1],d[ 5]};
		endcase
	endfunction

	// j_bs / j_xor computed from i_word (= addr[19:1])
	wire [3:0] j_bs_base = i_word[7:4] ^ select_xor[7:4];
	wire [3:0] j_bs      = j_bs_base ^ {1'b0, i_word[17], 2'b00};   // i & 0x20000
	wire [3:0] j_xor_base= i_word[3:0] ^ select_xor[3:0];
	wire [3:0] j_xor     = j_xor_base ^ {2'b00, i_word[18], 1'b0};  // i & 0x40000

	wire [15:0] dec = xor_lut(j_xor) ^ bs_apply(j_bs, ioctl_dout_in);

	// logical address: base + (i_word << 1) + byte_lo
	wire [26:0] addr_logical = cur_base + {6'd0, i_word, 1'b0} + {26'd0, byte_lo};

	// COMBINATIONAL output (no registers): ioctl_wait and data stay aligned with
	// zero clocks of delay so the SDRAM download pacing is not disturbed
	// (registering them loses words).
	assign ioctl_dout_out     = is_main ? dec          : ioctl_dout_in;
	assign ioctl_addr_out     = is_main ? addr_logical : ioctl_addr_in;
	assign ioctl_wr_out       = ioctl_wr_in;
	assign ioctl_index_out    = ioctl_index_in;
	assign ioctl_download_out = ioctl_download_in;
	assign remap_out          = is_main;

endmodule
