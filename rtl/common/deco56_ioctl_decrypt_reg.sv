//
// deco56_ioctl_decrypt_reg.sv — POCKET.
// DECO56 tile decryption on the ROM download stream (address remap, XOR, bitswap),
// with the outputs ALREADY REGISTERED: out(t) = decryption of the inputs of cycle
// t-1, i.e. exactly a combinational decryption followed by a register
// (ioctl_addr_r/ioctl_dout_r in Template.sv). Here the register sits BEFORE the logic:
//   - the three tables (2048 entries) are read synchronously -> M10K instead of
//     ~700 ALMs of logic (on MiSTer they are "logic" because of the asynchronous read);
//   - the other inputs of the logic are registered on the same edge.
// Exact retiming: f(reg(x)) = reg(f(x)) on every cycle, because f is combinational
// and the synchronous table is the table at the registered address.
//

module deco56_ioctl_decrypt_reg
(
	input  wire        clk,

	input  wire [26:0] ioctl_addr_in,
	input  wire [15:0] ioctl_dout_in,
	input  wire [15:0] ioctl_index_in,
	input  wire        ioctl_download_in,

	output wire [26:0] ioctl_addr_out_r,   // = reg(decrypted/remapped address)
	output wire [15:0] ioctl_dout_out_r,   // = reg(decrypted data)
	output wire        remap_out_r         // = reg(address is in a remapped region)
);

	localparam [26:0] T1_BASE   = 27'h110000;
	localparam [26:0] T1_END    = 27'h130000;
	localparam [26:0] T2_BASE   = 27'h130000;
	localparam [26:0] T2_END    = 27'h330000;
	localparam [26:0] T2HI_BASE = 27'h330000;
	localparam [26:0] T2HI_END  = 27'h430000;
	localparam [26:0] T3_BASE   = 27'h430000;
	localparam [26:0] T3_END    = 27'h630000;
	localparam [26:0] T3B_BASE  = 27'h630000;
	localparam [26:0] T3B_END   = 27'h830000;

	// ── before the register: only what the table address needs ──
	wire is_rom_dl = ioctl_download_in & (ioctl_index_in == 16'd0);

	wire in_t1   = is_rom_dl && (ioctl_addr_in >= T1_BASE)   && (ioctl_addr_in < T1_END);
	wire in_t2   = is_rom_dl && (ioctl_addr_in >= T2_BASE)   && (ioctl_addr_in < T2_END);
	wire in_t2hi = is_rom_dl && (ioctl_addr_in >= T2HI_BASE) && (ioctl_addr_in < T2HI_END);
	wire in_t3   = is_rom_dl && (ioctl_addr_in >= T3_BASE)   && (ioctl_addr_in < T3_END);
	wire in_t3b  = is_rom_dl && (ioctl_addr_in >= T3B_BASE)  && (ioctl_addr_in < T3B_END);

	wire is_remapped = in_t1 | in_t2 | in_t2hi | in_t3 | in_t3b;
	wire remap_only  = in_t2hi;

	wire [26:0] cur_base = in_t1   ? T1_BASE   :
	                       in_t2   ? T2_BASE   :
	                       in_t2hi ? T2HI_BASE :
	                       in_t3   ? T3_BASE   :
	                       in_t3b  ? T3B_BASE  : 27'd0;

	wire [25:0] wrel    = (ioctl_addr_in - cur_base) >> 1;
	wire [10:0] p_lo    = wrel[10:0];
	wire [14:0] blk_hi  = wrel[25:11];

	// ── synchronous-read tables (M10K) ──
	(* ramstyle = "M10K" *) reg [10:0] inv_addr_table [0:2047];
	(* ramstyle = "M10K" *) reg [3:0]  xor_table      [0:2047];
	(* ramstyle = "M10K" *) reg [2:0]  swap_of_p_table[0:2047];
	initial $readmemh("deco56_inv_address_table.hex", inv_addr_table);
	initial $readmemh("deco56_xor_table.hex",         xor_table);
	initial $readmemh("deco56_swap_of_p.hex",         swap_of_p_table);

	reg [10:0] i_lo_r;
	reg  [3:0] xi_r;
	reg  [2:0] pat_r;
	always @(posedge clk) i_lo_r <= inv_addr_table[p_lo];
	always @(posedge clk) xi_r   <= xor_table[p_lo];
	always @(posedge clk) pat_r  <= swap_of_p_table[p_lo];

	// ── register for the other inputs of the logic ──
	reg [26:0] addr_r;
	reg [15:0] dout_r;
	reg        remapped_r, remap_only_r;
	// POCKET timing: cur_base is always a multiple of 0x10000 and blk_hi enters in
	// multiples of 0x1000, so cur_base + {blk_hi, 11'd0, 1'b0} has the low 12 bits at
	// zero: the sum is done on the upper part only, BEFORE the register, and the logical
	// address becomes a concatenation (no 27-bit adder after the M10K).
	reg [14:0] hi_sum_r;
	always @(posedge clk) begin
		addr_r       <= ioctl_addr_in;
		dout_r       <= ioctl_dout_in;
		remapped_r   <= is_remapped;
		remap_only_r <= remap_only;
		hi_sum_r     <= cur_base[26:12] + {blk_hi};
	end

	// ── after the register: decryption logic ──
	function [15:0] xor_mask(input [3:0] idx);
		case (idx)
			4'h0: xor_mask = 16'hd556; 4'h1: xor_mask = 16'h73cb;
			4'h2: xor_mask = 16'h2963; 4'h3: xor_mask = 16'h4b9a;
			4'h4: xor_mask = 16'hb3bc; 4'h5: xor_mask = 16'hbc73;
			4'h6: xor_mask = 16'hcbc9; 4'h7: xor_mask = 16'haeb5;
			4'h8: xor_mask = 16'h1e6d; 4'h9: xor_mask = 16'hd5b5;
			4'ha: xor_mask = 16'he676; 4'hb: xor_mask = 16'h5cc5;
			4'hc: xor_mask = 16'h395a; 4'hd: xor_mask = 16'hdaae;
			4'he: xor_mask = 16'h2629; 4'hf: xor_mask = 16'he59e;
		endcase
	endfunction

	function [15:0] bitswap_apply(input [2:0] pat_idx, input [15:0] d);
		case (pat_idx)
			3'd0: bitswap_apply = {d[15],d[ 8],d[ 9],d[12],d[10],d[13],d[11],d[14], d[ 2],d[ 7],d[ 4],d[ 3],d[ 1],d[ 5],d[ 6],d[ 0]};
			3'd1: bitswap_apply = {d[12],d[10],d[11],d[ 9],d[ 8],d[15],d[14],d[13], d[ 6],d[ 0],d[ 3],d[ 5],d[ 7],d[ 4],d[ 2],d[ 1]};
			3'd2: bitswap_apply = {d[ 8],d[12],d[11],d[ 9],d[13],d[14],d[15],d[10], d[ 4],d[ 6],d[ 5],d[ 0],d[ 3],d[ 1],d[ 7],d[ 2]};
			3'd3: bitswap_apply = {d[ 8],d[ 9],d[10],d[13],d[11],d[15],d[14],d[12], d[ 5],d[ 4],d[ 0],d[ 7],d[ 2],d[ 6],d[ 1],d[ 3]};
			3'd4: bitswap_apply = {d[12],d[13],d[14],d[15],d[ 8],d[ 9],d[10],d[11], d[ 1],d[ 5],d[ 0],d[ 3],d[ 2],d[ 7],d[ 6],d[ 4]};
			3'd5: bitswap_apply = {d[14],d[15],d[13],d[ 8],d[12],d[10],d[11],d[ 9], d[ 1],d[ 2],d[ 7],d[ 6],d[ 4],d[ 3],d[ 0],d[ 5]};
			3'd6: bitswap_apply = {d[13],d[14],d[10],d[11],d[ 9],d[ 8],d[12],d[15], d[ 3],d[ 1],d[ 7],d[ 4],d[ 5],d[ 0],d[ 2],d[ 6]};
			3'd7: bitswap_apply = {d[ 9],d[ 8],d[14],d[10],d[15],d[11],d[13],d[12], d[ 6],d[ 0],d[ 5],d[ 2],d[ 4],d[ 1],d[ 3],d[ 7]};
		endcase
	endfunction

	wire [15:0] din_be    = {dout_r[7:0], dout_r[15:8]};
	wire [15:0] dec_phys  = bitswap_apply(pat_r, din_be ^ xor_mask(xi_r));
	// POCKET: mbd-02 region (remap only): the low byte after the swap is always 0.
	// In the MiSTer .rom that byte is already 0 (16-bit interleave with only mbd-02.10e on map="01");
	// the Pocket MRAs (pocket/mra) also put mbd-02.10e on map="10", because mra-tools-c wants every
	// byte of the group covered. Here the duplicated byte is forced back to 0: identical SDRAM with
	// either .rom.
	wire [15:0] data_phys = remap_only_r ? {dout_r[7:0], 8'h00} : dec_phys;
	wire [26:0] addr_logical = {hi_sum_r, i_lo_r, 1'b0};

	assign ioctl_addr_out_r = remapped_r ? addr_logical : addr_r;
	assign ioctl_dout_out_r = remapped_r ? data_phys    : dout_r;
	assign remap_out_r      = remapped_r;

endmodule
