// pause_overlay.sv — standalone pause overlay.
//   - pause=0: video passes through unchanged (purely combinational, no delay on the path).
//   - pause=1: dimmed video (>>1) + 48x48 logo (drawn at 2x) in the centre of the screen.
//
// Decoupled: reads only pause + render_x/y + video RGB. No registers on the
// video path, no HS/VS shift.
//
// Logo BRAM 2304x2 (1 M10K), read one clock ahead at render_x+1 so that q
// lines up with the current video pixel.

module pause_overlay (
	input  wire        clk,
	input  wire        pause,
	input  wire        clean,    // OSD option: bypass the overlay (no logo, no text)
	input  wire        vblank,   // external vblank, edge-detected for the scroll tick

	input  wire [9:0]  render_x,
	input  wire [8:0]  render_y,

	input  wire [7:0]  rgb_r_in,
	input  wire [7:0]  rgb_g_in,
	input  wire [7:0]  rgb_b_in,

	output wire [7:0]  rgb_r_out,
	output wire [7:0]  rgb_g_out,
	output wire [7:0]  rgb_b_out
);

// Effective overlay: pause active and clean off.
wire overlay_on = pause & ~clean;

// VBlank pulse: rising edge of the external vblank signal (frame boundary).
reg vblank_d;
always @(posedge clk) vblank_d <= vblank;
wire vblank_pulse = vblank & ~vblank_d;

// =====================================================================
// Logo placement: 48x48 source, SCALE 2x → 96x96, centred.
// Boogie Wings screen 320x240 (render_x 0..319). Centre = (160, 120).
// Top-left logo = (160-48, 120-48) = (112, 72).
// =====================================================================
localparam [9:0] LOGO_X    = 10'd112;   // (320-96)/2 = 112
localparam [8:0] LOGO_Y    = 9'd72;     // (240-96)/2 = 72
localparam [9:0] LOGO_XEND = LOGO_X + 10'd96;
localparam [8:0] LOGO_YEND = LOGO_Y + 9'd96;

// Read-ahead: the current pixel needs its address on the previous clock.
wire [9:0] x_ahead = render_x + 10'd1;
wire [9:0] dx10    = x_ahead - LOGO_X;
wire [9:0] dy10    = {1'b0, render_y} - {1'b0, LOGO_Y};

wire in_logo_ahead = overlay_on &&
	(x_ahead   >= LOGO_X) && (x_ahead   < LOGO_XEND) &&
	(render_y  >= LOGO_Y) && (render_y  < LOGO_YEND);

// SCALE 2x: dx/2, dy/2 (48x48 source drawn as 96x96)
wire [5:0] dx = dx10[6:1];
wire [5:0] dy = dy10[6:1];
// addr = dy*48 + dx = (dy<<5) + (dy<<4) + dx, max=47*48+47=2303
wire [11:0] logo_addr = {1'b0, dy, 5'd0} + {2'b0, dy, 4'd0} + {6'd0, dx};

// =====================================================================
// Logo BRAM 2304x2, initialised from logo/logo.mem
// =====================================================================
reg [1:0] logo_rom [0:2303] /* synthesis ramstyle = "M10K" */;
initial $readmemb("logo/logo.mem", logo_rom);
reg [1:0] logo_pix;
reg       in_logo_now;
always @(posedge clk) begin
	logo_pix    <= logo_rom[logo_addr];
	in_logo_now <= in_logo_ahead;
end

// Logo palette: pal0=black, pal1=magenta, pal2=cyan, pal3=white
reg [7:0] lr, lg, lb;
always @(*) case (logo_pix)
	2'd0: {lr, lg, lb} = 24'h000000;
	2'd1: {lr, lg, lb} = 24'hFF00FF;
	2'd2: {lr, lg, lb} = 24'h00E6E4;
	2'd3: {lr, lg, lb} = 24'hFFFFFF;
endcase

// The logo is always opaque (including pal0=black), as in Act Fancer/Blood Bros.
wire logo_opaque = 1'b1;

// =====================================================================
// Header "SUPPORTERS" — top, centred. 10 chars × 8 = 80 px.
// Screen 320 wide → ORIGIN_X = (320-80)/2 = 120.
// =====================================================================
wire       header_on;
wire [1:0] header_tier;
pause_text #(
	.W_CHARS      (10),
	.H_CHARS      (1),
	.MSG_ROWS     (1),
	.ORIGIN_X     (10'd120),   // (320-80)/2 = 120
	.ORIGIN_Y     (9'd16),     // top + 16 px margin
	.SCROLL_EN    (0),
	.FONT_FILE    ("logo/font_darius.hex"),
	.MSG_FILE     ("logo/header.mem")
) u_header (
	.clk          (clk),
	.active       (overlay_on),
	.vblank_pulse (vblank_pulse),
	.render_x     (render_x),
	.render_y     (render_y),
	.font_addr_o  (font_addr_a),
	.font_row_i   (font_row_a),
	.pixel_on     (header_on),
	.pixel_tier   (header_tier)
);

// =====================================================================
// Patron scroll — central area. 30 chars × 8 = 240 px.
// Screen 320 wide → ORIGIN_X = (320-240)/2 = 40. 24 visible rows. MSG_ROWS
// = the rows of logo/patrons.mem (30 x MSG_ROWS words, generated from
// logo/patrons.txt): the list ends with blank rows, the gap before the
// scroll starts again from the top.
// =====================================================================
wire       patron_on;
wire [1:0] patron_tier;
pause_text #(
	.W_CHARS       (30),
	.H_CHARS       (24),
	.MSG_ROWS      (57),   // POCKET: Gold and Silver supporters only (the MiSTer list has 70 rows)
	.ORIGIN_X      (10'd40),    // (320-240)/2 = 40
	.ORIGIN_Y      (9'd32),     // below the header
	.SCROLL_EN     (1),
	.SCROLL_PERIOD (3),
	.FONT_FILE     ("logo/font_darius.hex"),
	.MSG_FILE      ("logo/patrons.mem")
) u_patron (
	.clk          (clk),
	.active       (overlay_on),
	.vblank_pulse (vblank_pulse),
	.render_x     (render_x),
	.render_y     (render_y),
	.font_addr_o  (font_addr_b),
	.font_row_i   (font_row_b),
	.pixel_on     (patron_on),
	.pixel_tier   (patron_tier)
);

// SHARED font ROM: a single M10K for header+patron (dual read) instead of two copies.
// The pause overlay saves one M10K, which the OKI needs (the M10K pool is tight).
wire [9:0] font_addr_a, font_addr_b;
wire [7:0] font_row_a,  font_row_b;
pause_font u_font (
	.clk    (clk),
	.addr_a (font_addr_a),
	.q_a    (font_row_a),
	.addr_b (font_addr_b),
	.q_b    (font_row_b)
);

// =====================================================================
// Tier palette: 0=white 1=cyan 2=magenta 3=gold
// =====================================================================
function [23:0] tier_color;
	input [1:0] tier;
	begin
		case (tier)
			2'd0: tier_color = 24'hFFFFFF;
			2'd1: tier_color = 24'h00E6E4;
			2'd2: tier_color = 24'hFF00FF;
			2'd3: tier_color = 24'hFFD700;
		endcase
	end
endfunction

wire [23:0] header_rgb = 24'hFFD700;             // yellow/gold
wire [23:0] patron_rgb = tier_color(patron_tier);

// Priority: header > patron > logo > dim > raw
wire        text_on  = header_on | patron_on;
wire [23:0] text_rgb = header_on ? header_rgb : patron_rgb;

// =====================================================================
// Purely combinational output mux (no delay on the video path)
// =====================================================================
wire [7:0] dim_r = {1'b0, rgb_r_in[7:1]};
wire [7:0] dim_g = {1'b0, rgb_g_in[7:1]};
wire [7:0] dim_b = {1'b0, rgb_b_in[7:1]};

assign rgb_r_out = !overlay_on              ? rgb_r_in :
                   text_on                  ? text_rgb[23:16] :
                   in_logo_now & logo_opaque ? lr        :
                                              dim_r;
assign rgb_g_out = !overlay_on              ? rgb_g_in :
                   text_on                  ? text_rgb[15:8]  :
                   in_logo_now & logo_opaque ? lg        :
                                              dim_g;
assign rgb_b_out = !overlay_on              ? rgb_b_in :
                   text_on                  ? text_rgb[7:0]   :
                   in_logo_now & logo_opaque ? lb        :
                                              dim_b;

endmodule
