//
// deco146_base.sv
// Data East 146/104 protection chip — porting RTL.
//
// C++ reference: MAME deco146.cpp (read_data, read_protport,
// write_protport, reorder).
//
// Read latency: 2 ck (registered table BRAM + registered final output).
// For the 68K: internal wait1 of jtframe_68kdtack_cen + bus_busy 1 ck = 2 ck total.
//

module deco146_base #(
    parameter [7:0]  XOR_PORT  = 8'h2c,
    parameter [7:0]  MASK_PORT = 8'h36,
    parameter [7:0]  SOUND_PORT= 8'h64,
    parameter [7:0]  BANK_SWAP_READ_ADDR = 8'h78,
    parameter [15:0] MAGIC_READ_ADDR_XOR = 16'h44a,
    parameter        MAGIC_XOR_ENABLED = 1'b0,
    parameter [1:0]  ADDR_SCRAMBLE = 2'd0,   // 0=none, 1=reversed, 2=interleave
    parameter        TABLE_OFFSET_HEX  = "deco146_offset.hex",
    parameter        TABLE_MAPPING_HEX = "deco146_mapping.hex",
    parameter        TABLE_FLAGS_HEX   = "deco146_flags.hex",
    parameter integer SS_RB0_IDX        = 0,
    parameter integer SS_RB1_IDX        = 0
)(
    input  wire        clk,
    input  wire        reset,

    input  wire [11:0] cpu_addr,
    input  wire        cpu_cs,
    input  wire        cpu_rd,
    input  wire        cpu_wr,
    input  wire [15:0] cpu_wdata,
    input  wire  [1:0] cpu_dsn,
    output reg  [15:0] cpu_rdata,

    input  wire [15:0] port_a,
    input  wire [15:0] port_b,
    input  wire [15:0] port_c,

    output reg   [7:0] soundlatch_data,
    output reg         soundlatch_irq,
    input  wire        soundlatch_rd,
    output wire  [7:0] soundlatch_dout,

    // Savestate auto_ss (69 bits): DECO104 protection state. Does NOT include soundlatch_irq
    // (1-cycle transient pulse: saving it creates an artificial edge -> spurious FIFO push on restore).
    //  [15:0] xor_reg  [31:16] nand_reg  [32] current_rambank  [43:33] latch_addr
    //  [59:44] latch_data  [60] latch_flag  [68:61] soundlatch_data
    input  wire [68:0] dc_ss_in,
    output wire [68:0] dc_ss_out,
    input  wire        dc_ss_wr,
    // Savestate of rambank0/1 (128x16 protection RAM) via ssbus
    ssbus_if.slave     ss_rb0,
    ssbus_if.slave     ss_rb1
);

// ============================================================
// Address scramble
// ============================================================
wire [10:0] addr_w = cpu_addr[11:1];
reg [10:0] addr_scrambled;
always @(*) begin
    case (ADDR_SCRAMBLE)
        2'd1: begin // reversed (boogwing)
            addr_scrambled = {addr_w[10],
                              addr_w[0], addr_w[1], addr_w[2], addr_w[3], addr_w[4],
                              addr_w[5], addr_w[6], addr_w[7], addr_w[8], addr_w[9]};
        end
        2'd2: begin // interleave
            addr_scrambled = {addr_w[10],
                              addr_w[8], addr_w[9], addr_w[6], addr_w[7],
                              addr_w[4], addr_w[5], addr_w[2], addr_w[3],
                              addr_w[0], addr_w[1]};
        end
        default: addr_scrambled = addr_w;
    endcase
end

wire [10:0] magic_xor_w = {1'b0, MAGIC_READ_ADDR_XOR[10:1]};
// MAME deco146.cpp: the magic xor is applied ONLY in read_protport (lines 1217-1218),
// NOT in write_protport, so the write path needs a separate address.
wire [10:0] addr_for_lookup = MAGIC_XOR_ENABLED ? (addr_scrambled ^ magic_xor_w) : addr_scrambled;
wire [10:0] addr_for_write  = addr_scrambled;

// ============================================================
// Lookup tables (BRAM, .hex initialized)
// ============================================================
(* ramstyle = "M10K" *) reg [15:0] tbl_offset  [0:1023];
(* ramstyle = "M10K" *) reg [79:0] tbl_mapping [0:1023];
(* ramstyle = "M10K" *) reg [1:0]  tbl_flags   [0:1023];
initial begin
    $readmemh(TABLE_OFFSET_HEX,  tbl_offset);
    $readmemh(TABLE_MAPPING_HEX, tbl_mapping);
    $readmemh(TABLE_FLAGS_HEX,   tbl_flags);
end

// ============================================================
// RAMBANK 2 x 128 word
// ============================================================
// POCKET: each bank has ONE write port and ONE read port, so Quartus maps it
// to memory (M10K) instead of 2048 registers + a 128:1 mux (~3,500 ALMs per
// bank). With two ports per side (CPU and savestate) the RAM is not inferred.
// CPU and savestate NEVER access the bank at the same time (the CPU is halted
// during a savestate), so the address is selected between the two:
//   write: savestate when the savestate writes, otherwise CPU (only outside
//          reset and dc_ss_wr);
//   read : savestate address when the savestate accesses the bank,
//          otherwise rb_idx_r. Registered read (1 cycle), both for
//          s1_rb0/1 and for rb0/1_ss_rd.
(* ramstyle = "M10K" *) reg [15:0] rambank0 [0:127];
(* ramstyle = "M10K" *) reg [15:0] rambank1 [0:127];
integer init_i;
initial begin
    for (init_i = 0; init_i < 128; init_i = init_i + 1) begin
        rambank0[init_i] = 16'hFFFF;
        rambank1[init_i] = 16'hFFFF;
    end
end
reg current_rambank;
reg [15:0] xor_reg;
reg [15:0] nand_reg;

reg [10:0] latch_addr;
reg [15:0] latch_data;
reg        latch_flag;

// ============================================================
// Pipeline read: 1 ck registered (BRAM read + source select + reorder + xor/nand)
// ============================================================
// Stage 0 (combinatorial): addr_for_lookup
// Stage 1 (clocked):       read BRAM, read rambank, sample ports
// Stage 2 (combinatorial): reorder + xor/nand + latch_hit mux
// Stage 3 (clocked):       cpu_rdata

reg [15:0] s1_offset;
reg [79:0] s1_mapping;
reg [1:0]  s1_flags;
wire [15:0] s1_rb0, s1_rb1;   // POCKET: registered RAM output (rb0_q/rb1_q)
reg [15:0] s1_pa, s1_pb, s1_pc;
reg        s1_latch_hit;
reg [15:0] s1_latch_val;
reg        s1_cb_bank;

wire latch_hit_w = cpu_cs && cpu_rd && (addr_for_lookup == latch_addr) && latch_flag;

// REGISTERED rambank index (timing-critical path). In a single cycle the chain
// address -> 1024-entry tbl_offset table -> 7-bit index -> 16-bit bank read
// does not fit the 10.416 ns clock period; split over two cycles, each half
// (table lookup, bank read) fits.
// This adds NO latency and does not change the bus wait states: the index is
// registered free-running from the address, which fx68k holds stable from S1,
// while cpu_cs/cpu_rd arrive with AS in S2, i.e. one CPU clock later (= 7 core
// clocks). When the read starts, rb_idx_r is already correct and s1_rb0 comes
// out in the same cycle as with a combinational index.
// The wait states must NOT be lengthened: cpu_rd is a level for the whole bus
// cycle and the current_rambank toggle has no edge detect, so one extra cycle
// would change its parity and flip the protection bank.
reg [6:0] rb_idx_r;
always @(posedge clk) rb_idx_r <= tbl_offset[addr_for_lookup[9:0]][7:1];

always @(posedge clk) begin
    s1_offset    <= tbl_offset[addr_for_lookup[9:0]];
    s1_mapping   <= tbl_mapping[addr_for_lookup[9:0]];
    s1_flags     <= tbl_flags[addr_for_lookup[9:0]];
    s1_pa        <= port_a;
    s1_pb        <= port_b;
    s1_pc        <= port_c;
    s1_latch_hit <= latch_hit_w;
    s1_latch_val <= latch_data;
    s1_cb_bank   <= current_rambank;
end

// Stage 2 (combinatorial)
function [15:0] reorder_fn(input [15:0] src, input [79:0] map);
    integer i;
    reg [4:0] dest;
    begin
        reorder_fn = 16'd0;
        for (i = 0; i < 16; i = i + 1) begin
            dest = map[i*5 +: 5];
            if (src[i] && (dest[4] == 1'b0))
                reorder_fn[dest[3:0]] = 1'b1;
        end
    end
endfunction

reg [15:0] src_sel;
always @(*) begin
    case (s1_offset)
        16'h8000: src_sel = s1_pa;
        16'h8001: src_sel = s1_pb;
        16'h8002: src_sel = s1_pc;
        default:  src_sel = s1_cb_bank ? s1_rb1 : s1_rb0;
    endcase
end

reg [15:0] reord;
always @(*) reord = reorder_fn(src_sel, s1_mapping);

reg [15:0] final_data;
always @(*) begin
    final_data = reord;
    if (s1_flags[0]) final_data = final_data ^ xor_reg;
    if (s1_flags[1]) final_data = final_data & ~nand_reg;
end

// Stage 3: register final output (1 ck total latency)
always @(posedge clk) begin
    if (s1_latch_hit) cpu_rdata <= s1_latch_val;
    else              cpu_rdata <= final_data;
end

// ============================================================
// Bankswitch on read: triggers one ck after the lookup
// ============================================================
always @(posedge clk) begin
    if (reset) begin
        current_rambank <= 1'b0;
    end else if (dc_ss_wr) begin
        current_rambank <= dc_ss_in[32];   // savestate restore (transparent)
    end else begin
        // s1_offset[15]=0 (= rambank) and [7:0] == BANK_SWAP_READ_ADDR
        if (cpu_cs && cpu_rd && !s1_latch_hit
            && s1_offset[15] == 1'b0 && s1_offset[7:0] == BANK_SWAP_READ_ADDR)
            current_rambank <= ~current_rambank;
    end
end

// ============================================================
// Write protport
// ============================================================
always @(posedge clk) begin
    if (reset) begin
        xor_reg  <= 16'h0000;
        nand_reg <= 16'h0000;
        soundlatch_data <= 8'h00;
        soundlatch_irq  <= 1'b0;
        latch_addr <= 11'h7FF;
        latch_data <= 16'h0000;
        latch_flag <= 1'b0;
    end else if (dc_ss_wr) begin
        // Savestate restore (has priority, transparent when SS is idle): reloads the protection registers.
        xor_reg         <= dc_ss_in[15:0];
        nand_reg        <= dc_ss_in[31:16];
        latch_addr      <= dc_ss_in[43:33];
        latch_data      <= dc_ss_in[59:44];
        latch_flag      <= dc_ss_in[60];
        soundlatch_data <= dc_ss_in[68:61];
        // soundlatch_irq is NOT restored: it is a 1-cycle transient pulse. The wrapper's edge detect
        // (sl_pulse_d) is saved in AUDIO_BUS -> no artificial edge on restore.
    end else begin
        soundlatch_irq <= 1'b0;

        // POCKET: the rambank0/1 writes (savestate and CPU) are in the RAM
        // block at the end of the file, with the same conditions.

        if (cpu_cs && cpu_wr) begin
            latch_addr <= addr_for_write;
            latch_data <= cpu_wdata;
            latch_flag <= 1'b1;

            // Special port writes (byte addr = addr_for_write << 1)
            if ((addr_for_write[7:0] << 1) == {1'b0, XOR_PORT})
                xor_reg <= cpu_wdata;
            else if ((addr_for_write[7:0] << 1) == {1'b0, MASK_PORT})
                nand_reg <= cpu_wdata;
            else if ((addr_for_write[7:0] << 1) == {1'b0, SOUND_PORT}) begin
                soundlatch_data <= cpu_wdata[7:0];
                soundlatch_irq  <= 1'b1;
            end
        end

        // Clear latch flag after a non-latched read
        if (cpu_cs && cpu_rd && !latch_hit_w) begin
            latch_flag <= 1'b0;
        end

        if (soundlatch_rd) begin
            soundlatch_irq <= 1'b0;
        end
    end
end

assign soundlatch_dout = soundlatch_data;

// ============================================================
// Savestate: SAVE of the protection registers (combinational, does not affect the logic).
// ============================================================
assign dc_ss_out = {soundlatch_data, latch_flag, latch_data,
                    latch_addr, current_rambank, nand_reg, xor_reg};

// ============================================================
// Savestate rambank0/1 (128x16 RAM): dedicated SS read/write port.
// With SS idle (no access) the RAM is written only by the CPU (original logic, transparent).
// During SS: the SS port takes over addr/we/data and reads the words for save / writes them for restore.
// ============================================================
wire        rb0_ss_sel = ss_rb0.access(SS_RB0_IDX);
wire        rb1_ss_sel = ss_rb1.access(SS_RB1_IDX);
wire [15:0] rb0_ss_rd, rb1_ss_rd;   // POCKET: registered RAM output (rb0_q/rb1_q)
// NB: the SS WRITE of rambank0/1 is in the RAM block at the end of the file (same block as the
// CPU write) to avoid a double driver. Here only read/setup/ack/response.
reg rb0_rd_d, rb1_rd_d;
always @(posedge clk) begin
    ss_rb0.setup(SS_RB0_IDX, 128, 1);   // 128 word, width 1 = 16 bit
    ss_rb1.setup(SS_RB1_IDX, 128, 1);
    rb0_rd_d <= rb0_ss_sel & ss_rb0.read;
    rb1_rd_d <= rb1_ss_sel & ss_rb1.read;
    if (rb0_ss_sel & ss_rb0.write) ss_rb0.write_ack(SS_RB0_IDX);
    if (rb1_ss_sel & ss_rb1.write) ss_rb1.write_ack(SS_RB1_IDX);
    if (rb0_rd_d) ss_rb0.read_response(SS_RB0_IDX, {48'b0, rb0_ss_rd});
    if (rb1_rd_d) ss_rb1.read_response(SS_RB1_IDX, {48'b0, rb1_ss_rd});
end

// ============================================================
// POCKET: rambank0/1 as RAM with 1 write + 1 read port per bank
// ============================================================
// Write: same conditions as the "else" branch of the Write protport block
// (outside reset and dc_ss_wr); savestate or CPU (never both).
wire        rb_wr_ok  = ~reset & ~dc_ss_wr;
wire        rb0_ss_wr = rb0_ss_sel & ss_rb0.write;
wire        rb1_ss_wr = rb1_ss_sel & ss_rb1.write;
wire        rb_cpu_wr = cpu_cs & cpu_wr;
wire        rb0_we    = rb_wr_ok & (rb0_ss_wr | (rb_cpu_wr & ~current_rambank));
wire        rb1_we    = rb_wr_ok & (rb1_ss_wr | (rb_cpu_wr &  current_rambank));
wire  [6:0] rb0_wa    = rb0_ss_wr ? ss_rb0.addr[6:0]  : addr_for_write[7:1];
wire  [6:0] rb1_wa    = rb1_ss_wr ? ss_rb1.addr[6:0]  : addr_for_write[7:1];
wire [15:0] rb0_wd    = rb0_ss_wr ? ss_rb0.data[15:0] : cpu_wdata;
wire [15:0] rb1_wd    = rb1_ss_wr ? ss_rb1.data[15:0] : cpu_wdata;
// Registered read: savestate address when it accesses the bank, otherwise
// the CPU one (rb_idx_r). Same 1-cycle latency for both sides.
wire  [6:0] rb0_ra    = rb0_ss_sel ? ss_rb0.addr[6:0] : rb_idx_r;
wire  [6:0] rb1_ra    = rb1_ss_sel ? ss_rb1.addr[6:0] : rb_idx_r;
reg  [15:0] rb0_q, rb1_q;

always @(posedge clk) begin
    if (rb0_we) rambank0[rb0_wa] <= rb0_wd;
    rb0_q <= rambank0[rb0_ra];
end
always @(posedge clk) begin
    if (rb1_we) rambank1[rb1_wa] <= rb1_wd;
    rb1_q <= rambank1[rb1_ra];
end

assign s1_rb0    = rb0_q;
assign s1_rb1    = rb1_q;
assign rb0_ss_rd = rb0_q;
assign rb1_ss_rd = rb1_q;

endmodule
