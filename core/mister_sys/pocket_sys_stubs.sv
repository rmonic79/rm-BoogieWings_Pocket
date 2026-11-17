// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) Umberto Parisi (rmonic79).
//
// Pocket versions of MiSTer framework modules (its sys/ folder) that emu
// instantiates directly. Same ports as the originals; on the Pocket their
// work is done by the Analogue scaler (rotation, aspect ratio, scaling), so
// here they are transparent. The core (emu) is not changed by a single line.
//
//   video_freak   : no MiSTer crop/scaling: VGA_DE = VGA_DE_IN, AR passes through.

module video_freak
(
	input             CLK_VIDEO,
	input             CE_PIXEL,
	input             VGA_VS,
	input      [11:0] HDMI_WIDTH,
	input      [11:0] HDMI_HEIGHT,
	output            VGA_DE,
	output reg [12:0] VIDEO_ARX,
	output reg [12:0] VIDEO_ARY,

	input             VGA_DE_IN,
	input      [11:0] ARX,
	input      [11:0] ARY,
	input      [11:0] CROP_SIZE,
	input       [4:0] CROP_OFF,
	input       [2:0] SCALE
);

assign VGA_DE = VGA_DE_IN;
always @(posedge CLK_VIDEO) begin
	VIDEO_ARX <= {1'b0, ARX};
	VIDEO_ARY <= {1'b0, ARY};
end

endmodule
