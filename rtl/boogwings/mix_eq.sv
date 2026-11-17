// SPDX-License-Identifier: GPL-3.0-or-later
//
// mix_eq — correction of the audio mix towards MAME: 4 cascaded biquads per channel at 192 kHz:
//   S0 low-shelf  461 Hz  +1.80 dB
//   S1 peaking   1525 Hz  -0.72 dB  Q 6.00
//   S2 peaking   6107 Hz  -3.33 dB  Q 1.39
//   S3 high-shelf 6019 Hz +1.26 dB
//
// The parameters come from two aligned recordings of the same attract sequence, MAME and
// core (fit weighted by the measurement uncertainty); the coefficients and a bit-exact
// integer model of the filter are generated from them. After the correction no band (50 Hz - 12.5 kHz)
// stays outside the uncertainty and the rms matches MAME within 0.07 dB.
//
// Direct Form I, Q2.24 coefficients (27 bit), internal samples Q18.8 (26 bit, saturated).
// A single 27x26 multiplier reused sequentially: 3 clk per term + 1 to close the
// stage = 16 clk per stage, 128 clk per stereo sample out of 500 available (96 MHz / 192 kHz).
module mix_eq (
	input  wire               clk,
	input  wire               reset,
	input  wire               ce,          // 1 clk per sample (192 kHz), already stopped during pause
	input  wire signed [15:0] in_l,
	input  wire signed [15:0] in_r,
	output reg  signed [15:0] out_l,
	output reg  signed [15:0] out_r
);

localparam signed [26:0] S0_B0 = 27'sd16795809;
localparam signed [26:0] S0_B1 = -27'sd33214124;
localparam signed [26:0] S0_B2 = 27'sd16422511;
localparam signed [26:0] S0_A1 = -27'sd33214517;
localparam signed [26:0] S0_A2 = 27'sd16440710;
localparam signed [26:0] S1_B0 = 27'sd16771456;
localparam signed [26:0] S1_B1 = -27'sd33368055;
localparam signed [26:0] S1_B2 = 27'sd16638201;
localparam signed [26:0] S1_A1 = -27'sd33368055;
localparam signed [26:0] S1_A2 = 27'sd16632440;
localparam signed [26:0] S2_B0 = 27'sd16350935;
localparam signed [26:0] S2_B1 = -27'sd30262296;
localparam signed [26:0] S2_B2 = 27'sd14525947;
localparam signed [26:0] S2_A1 = -27'sd30262296;
localparam signed [26:0] S2_A2 = 27'sd14099665;
localparam signed [26:0] S3_B0 = 27'sd19198141;
localparam signed [26:0] S3_B1 = -27'sd33263142;
localparam signed [26:0] S3_B2 = 27'sd14674587;
localparam signed [26:0] S3_A1 = -27'sd28737278;
localparam signed [26:0] S3_A2 = 27'sd12569647;

function signed [25:0] sat26(input signed [55:0] v);
	if      (v >  $signed(56'sd33554431)) sat26 = 26'sd33554431;
	else if (v < -$signed(56'sd33554432)) sat26 = -26'sd33554432;
	else                                  sat26 = v[25:0];
endfunction

function signed [15:0] sat16(input signed [25:0] v);
	if      (v >  $signed(26'sd32767)) sat16 = 16'sd32767;
	else if (v < -$signed(26'sd32768)) sat16 = -16'sd32768;
	else                               sat16 = v[15:0];
endfunction

// state: z[{ch, stage, k}], k = 0 x1, 1 x2, 2 y1, 3 y2
reg        busy, ch, sub;
reg  [1:0] stg;
reg  [2:0] term;
reg  [1:0] ph;
reg signed [15:0] in_r_q;
reg signed [25:0] s;
reg signed [26:0] ma;
reg signed [25:0] mb;
reg signed [52:0] prod;
reg signed [55:0] acc;

wire signed [55:0] prod_x = {{3{prod[52]}}, prod};
wire signed [55:0] acc_sh = acc >>> 24;
wire signed [25:0] y_new  = sat26(acc_sh);

reg signed [26:0] coef;
always @(*) begin
	case ({stg, term})
		5'b00_000: coef = S0_B0;  5'b00_001: coef = S0_B1;  5'b00_010: coef = S0_B2;
		5'b00_011: coef = S0_A1;  5'b00_100: coef = S0_A2;
		5'b01_000: coef = S1_B0;  5'b01_001: coef = S1_B1;  5'b01_010: coef = S1_B2;
		5'b01_011: coef = S1_A1;  5'b01_100: coef = S1_A2;
		5'b10_000: coef = S2_B0;  5'b10_001: coef = S2_B1;  5'b10_010: coef = S2_B2;
		5'b10_011: coef = S2_A1;  5'b10_100: coef = S2_A2;
		5'b11_000: coef = S3_B0;  5'b11_001: coef = S3_B1;  5'b11_010: coef = S3_B2;
		5'b11_011: coef = S3_A1;  default:   coef = S3_A2;
	endcase
end
// POCKET (fit): the z state is held in an M10K instead of 832 flip-flops + multiplexers.
// One 104-bit word {x1, x2, y1, y2} per {ch, stage}: one write per cycle (end of stage)
// and a registered read at the address of the current stage.
// - zq = cell of the stage from the 2nd cycle of the stage on; its first use is at term 1
//   (4th cycle) and no write touches that cell before the end of the stage.
// - At the end of a stage the same cell is written and read (read data not guaranteed):
//   that data is in zq only in the 1st cycle of the next stage, which uses s (term 0).
// - Reset clears one cell per cycle (8 cycles): the game reset always lasts
//   >= 2^17 clk (reset_hold_cnt in Template.sv), so the clear is complete by the end of reset.
// Cost: 3 M10K (256x40).
wire   [2:0] zi   = {ch, stg};
reg    [2:0] zclr = 3'd0;
wire         z_we = reset | (busy & (ph == 2'd3));       // end of stage in the block below
wire   [2:0] zwa  = reset ? zclr : zi;
wire [103:0] zq;                                         // {x1, x2, y1, y2} of cell zi
wire [103:0] zwd  = reset ? 104'd0 : {s, zq[103:78], y_new, zq[51:26]};
always @(posedge clk) if (reset) zclr <= zclr + 3'd1;
altsyncram #(
	.operation_mode                     ("DUAL_PORT"),
	.width_a                            (104),
	.widthad_a                          (3),
	.numwords_a                         (8),
	.width_b                            (104),
	.widthad_b                          (3),
	.numwords_b                         (8),
	.width_byteena_a                    (1),
	.address_reg_b                      ("CLOCK0"),
	.outdata_reg_b                      ("UNREGISTERED"),
	.clock_enable_input_a               ("BYPASS"),
	.clock_enable_input_b               ("BYPASS"),
	.clock_enable_output_b              ("BYPASS"),
	.ram_block_type                     ("M10K"),
	.maximum_depth                      (256),
	.intended_device_family             ("Cyclone V"),
	.lpm_type                           ("altsyncram"),
	.power_up_uninitialized             ("FALSE"),
	.read_during_write_mode_mixed_ports ("DONT_CARE")
) u_zram (
	.clock0         (clk),
	.address_a      (zwa),
	.data_a         (zwd),
	.wren_a         (z_we),
	.address_b      (zi),
	.q_b            (zq),
	.aclr0          (1'b0),
	.aclr1          (1'b0),
	.addressstall_a (1'b0),
	.addressstall_b (1'b0),
	.byteena_a      (1'b1),
	.byteena_b      (1'b1),
	.clock1         (1'b1),
	.clocken0       (1'b1),
	.clocken1       (1'b1),
	.clocken2       (1'b1),
	.clocken3       (1'b1),
	.data_b         ({104{1'b1}}),
	.eccstatus      (),
	.q_a            (),
	.rden_a         (1'b1),
	.rden_b         (1'b1),
	.wren_b         (1'b0)
);
reg signed [25:0] samp;
always @(*) begin
	case (term)
		3'd0:    samp = s;
		3'd1:    samp = zq[103:78];
		3'd2:    samp = zq[77:52];
		3'd3:    samp = zq[51:26];
		default: samp = zq[25:0];
	endcase
end

integer i;
always @(posedge clk) begin
	if (reset) begin
		busy <= 1'b0; ph <= 2'd0; term <= 3'd0; ch <= 1'b0; stg <= 2'd0;
		acc <= 56'sd0; out_l <= 16'sd0; out_r <= 16'sd0;
	end else if (!busy) begin
		if (ce) begin
			busy <= 1'b1; ch <= 1'b0; stg <= 2'd0; term <= 3'd0; ph <= 2'd0;
			s <= {{2{in_l[15]}}, in_l, 8'd0};
			in_r_q <= in_r;
			acc <= 56'sd0;
		end
	end else begin
		case (ph)
			2'd0: begin                                   // operands
				ma  <= coef;
				mb  <= samp;
				sub <= (term >= 3'd3);
				ph  <= 2'd1;
			end
			2'd1: begin                                   // product (DSP)
				prod <= ma * mb;
				ph   <= 2'd2;
			end
			2'd2: begin                                   // accumulate
				acc <= sub ? acc - prod_x : acc + prod_x;
				if (term == 3'd4) ph <= 2'd3;
				else begin term <= term + 3'd1; ph <= 2'd0; end
			end
			default: begin                                // end of stage
				acc  <= 56'sd0;
				term <= 3'd0;
				ph   <= 2'd0;
				s    <= y_new;
				if (stg != 2'd3) begin
					stg <= stg + 2'd1;
				end else begin
					stg <= 2'd0;
					if (!ch) begin
						out_l <= sat16(y_new >>> 8);
						ch    <= 1'b1;
						s     <= {{2{in_r_q[15]}}, in_r_q, 8'd0};
					end else begin
						out_r <= sat16(y_new >>> 8);
						busy  <= 1'b0;
					end
				end
			end
		endcase
	end
end

endmodule
