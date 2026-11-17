// BoogieWings Pocket settings (included by the framework's core_top.sv).
// All values come from the MiSTer core: MRA, CONF_STR, DDR3 addresses.

// ---- files and download (MRA "rm Boogie Wings (Euro v1.5, 92.12.07).mra")
localparam [15:0]  CFG_ROM_SLOT    = 16'd1;   // data slot id of the .rom (data.json)
localparam [15:0]  CFG_ROM_INDEX   = 16'd0;   // <rom index="0">
localparam [15:0]  CFG_MOD_INDEX   = 16'd1;   // <rom index="1"><part>00</part>
localparam integer CFG_MOD_LEN     = 1;       // 1 byte
localparam integer CFG_DIP_LEN     = 8;       // Main_MiSTer sends 8 DIP bytes (index 254)
localparam [63:0]  CFG_DIP_DEFAULT = 64'h0000000000007FFF;   // <switches default="FF,7F">
localparam [31:0]  CFG_MOD_DEFAULT = 32'h00000000;

// ---- initial status: all as on MiSTer (0)
localparam [127:0] CFG_STATUS_DEFAULT = 128'h0;

// ---- buttons: the core reads joy[4] Shot, joy[5] Bomb, joy[10] Start,
//      joy[11] Coin, joy[12] Pause (Template.sv; MRA "Shot,Bomb,-,-,-,-,Start,
//      Coin,Pause") -> joystick[4+i]
//      entry i = {valid, Pocket key}: 4 A, 5 B, 6 X, 7 Y, 8 L1, 9 R1,
//      14 select, 15 start
localparam [59:0]  CFG_BTN_MAP = {
	5'd0, 5'd0, 5'd0,       // 11..9 (9 = joy[13], the MiSTer savestate key: unused)
	{1'b1, 4'd8},           // 8 Pause -> L1
	{1'b1, 4'd14},          // 7 Coin  -> select
	{1'b1, 4'd15},          // 6 Start -> start
	5'd0, 5'd0, 5'd0, 5'd0, // 5..2 unused
	{1'b1, 4'd5},           // 1 Bomb  -> B
	{1'b1, 4'd4}            // 0 Shot  -> A
};

// ---- MiSTer DDR3 -> Pocket PSRAM (bytes)
//      W0: sprite chip0, ddram_4port port 4 (download at 0x30400000, 4 MB)
//      W1: sprite chip1, ddram_4port port 9 (0x30800000, 4 MB)
//      W2: OKI #0/#1 samples, ports 5/6 (0x35500000 / 0x35580000, 1 MB)
//      W3: savestate, region 0 of "SS3E000000:200000" (2 MB)
//      The other savestate regions (MiSTer slots 2-4) are left out: the
//      Pocket uses only APF slot 0.
localparam [31:0]  CFG_W0_DDR   = 32'h30400000;
localparam [31:0]  CFG_W0_PSRAM = 32'h00000000;
localparam integer CFG_W0_LOG2  = 22;          // 4 MB
localparam [31:0]  CFG_W1_DDR   = 32'h30800000;
localparam [31:0]  CFG_W1_PSRAM = 32'h00400000;
localparam integer CFG_W1_LOG2  = 22;          // 4 MB
localparam [31:0]  CFG_W2_DDR   = 32'h35500000;
localparam [31:0]  CFG_W2_PSRAM = 32'h00800000;
localparam integer CFG_W2_LOG2  = 20;          // 1 MB
localparam [31:0]  CFG_W3_DDR   = 32'h3E000000;
localparam [31:0]  CFG_W3_PSRAM = 32'h00A00000;
localparam integer CFG_W3_LOG2  = 21;          // 2 MB
localparam integer CFG_SS_WIN   = 3;           // savestate window (load monitor)

// ---- PSRAM area where the Pocket writes the .rom (from 12 MB up)
localparam [24:0]  CFG_STAGE_BYTE = 25'h0C00000;

// ---- savestate: slot 0 = region 0, sub-slot 0 (save_state_data):
//      block at 0x3E000010, 0x3F000 bytes; the save ends by rewriting
//      the region header at 0x3E000000. Commands: R[94] save, R[95] load.
localparam         CFG_SS_ENABLE   = 1;
localparam [24:0]  CFG_SS_BYTE     = 25'h0A00010;   // = W3_PSRAM + 0x10
localparam [31:0]  CFG_SS_SIZE     = 32'h0003F000;
localparam [31:0]  CFG_SS_HDR_DDR  = 32'h3E000000;
localparam integer CFG_SS_SAVE_BIT = 94;
localparam integer CFG_SS_LOAD_BIT = 95;

// ---- width of emu's HPS_BUS (BoogieWings sys/hps_io.sv: inout [45:0] HPS_BUS)
localparam integer CFG_HPS_BUS_W = 46;

// ---- PSRAM: emu clock 96 MHz -> T_ACC = ceil(70 / 10.42) + 1 = 8
localparam integer CFG_PSRAM_TACC = 8;

// ---- video: active-high syncs (Template.sv: HSync = hcnt in [340,372))
localparam CFG_HS_POL = 1;
localparam CFG_VS_POL = 1;

// scaler slot (video.json): a single mode, 320x240 horizontal
function [2:0] cfg_slot(input [127:0] st);
	cfg_slot = 3'd0;
endfunction
