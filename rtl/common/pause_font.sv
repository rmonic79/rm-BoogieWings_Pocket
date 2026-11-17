// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of BoogieWings_MiSTer.
    GPL-3.
    Author: Umberto Parisi (rmonic79)
*/

// pause_font.sv — SHARED 8x8 font ROM (1 M10K) for the pause overlay.
// Instantiated ONCE in pause_overlay and serving both pause_text instances
// (header + patron) through two independent read ports (dual-port M10K), so the
// font is NOT duplicated (2 M10K -> 1) and does not take M10K from the OKI audio pool.

module pause_font #(
	parameter FONT_FILE = "logo/font_darius.hex"
) (
	input  wire       clk,
	input  wire [9:0] addr_a,   // {ascii, row} instance A (header)
	output reg  [7:0] q_a,
	input  wire [9:0] addr_b,   // {ascii, row} instance B (patron)
	output reg  [7:0] q_b
);

(* ramstyle = "M10K, no_rw_check" *) reg [7:0] font_rom [0:1023];
initial $readmemh(FONT_FILE, font_rom);

always @(posedge clk) begin
	q_a <= font_rom[addr_a];
	q_b <= font_rom[addr_b];
end

endmodule
