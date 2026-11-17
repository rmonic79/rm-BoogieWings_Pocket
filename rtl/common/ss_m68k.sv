/*  This file is part of BoogieWings_MiSTer.
    GPL-3.
    Original author: Martin Donlon (wickerwaka) — Arcade-TaitoF2 savestate system.
    Modified/adapted for BoogieWings by: Umberto Parisi (rmonic79)
*/

//============================================================================
//  ss_m68k — 68000 savestate (68K mini-handler that pushes the state into work RAM)
//
//  Ported from Arcade-TaitoF2 (Martin Donlon), F2.sv:160-385,1042,1114-1116.
//  It does NOT extract fx68k's internal registers: it forces the CPU to run a mini-handler
//  (ss_irq_handler, 68K code) that pushes all registers onto the stack (= work RAM,
//  already saved via the adaptor) and writes the SSP to an intercepted scratch address.
//  On restore it injects a custom reset vector -> the CPU restarts and restores via rte.
//
//  BoogieWings adaptation: SSP scratch address = 0xFF0000 (outside the real 68K map:
//  ROM 0x0xxxxx, RAM 0x20xxxx, video 0x24-0x28, ace 0x3C). Intercepted here.
//============================================================================

`timescale 1ns / 1ps

module ss_m68k #(
	parameter integer SS_GLOB_IDX = 0
) (
	input  wire        clk,
	input  wire        ce_cpu,        // CPU clock enable (for the reset counter timing)

	// 68000 bus (observed)
	input  wire [23:0] cpu_word_addr, // = {fx_addr, 1'b0}
	input  wire [1:0]  cpu_ds_n,      // {uds_n, lds_n}
	input  wire        cpu_rw,        // 1=read, 0=write
	input  wire [2:0]  cpu_fc,        // function code
	input  wire        iack_n,        // ~(&cpu_fc) — low during IACK
	input  wire [15:0] cpu_data_out,  // data written by the CPU (to capture the SSP)

	// Triggers (from savestate_ui)
	input  wire        do_save,
	input  wire        do_restore,
	// REAL frame-aligned pause (= paused_safe_r of the top, = obj_paused of F2). NOT the
	// combinational paused_safe (which includes ss_pause and satisfies itself). The FSM waits for
	// paused_real BEFORE gather/scatter, so save/restore happen with CPU+audio TRULY stopped.
	input  wire        paused_real,


	// To memory_stream (via save_state_data)
	output reg         ss_mem_write,  // pulse: starts the save to DDR
	output reg         ss_mem_read,   // pulse: starts the load from DDR
	input  wire        ss_busy,       // memory_stream busy
	input  wire        slot_empty,    // 1 = sub-slot never written: do NOT apply the restore

	// Global SSP state via ssbus (dedicated SSIDX)
	ssbus_if.slave     ss_glob,

	// Overrides to the CPU
	output wire        ss_din_en,     // 1: cpu_din = ss_din_data (handler/vector)
	output wire [15:0] ss_din_data,
	output wire        ss_irq,        // 1: forces IPL7 (autovector)
	output wire        ss_reset,      // 1: reset fx68k (restore)
	output wire        ss_pause,      // 1: game paused
	output wire        ss_cpu_exec,   // 1: the CPU runs even when paused (executes the handler)
	output wire        ss_restore_done, // pulse: restore finished, CPU restarted on normal code
	output reg  [3:0]  ss_state_out
);

// Scratch address where the mini-handler writes the SSP (intercepted, not real RAM).
localparam [23:0] SS_SCRATCH = 24'hFF0000;

// 68K mini-handler (F2.sv:187-205). Executed when ss_save_active: pushes all the
// registers + USP onto the stack (work RAM) and writes the SSP to SS_SCRATCH; on return it restores them.
reg [15:0] ss_irq_handler [0:15];
initial begin
	ss_irq_handler[ 0] = 16'h48e7; ss_irq_handler[ 1] = 16'hfffe; // movem.l d0-d7/a0-a6,-(a7)
	ss_irq_handler[ 2] = 16'h4e6e;                                // move.l usp,a6
	ss_irq_handler[ 3] = 16'h2f0e;                                // move.l a6,-(a7)
	ss_irq_handler[ 4] = 16'h4df9; ss_irq_handler[ 5] = 16'h00ff; ss_irq_handler[ 6] = 16'h0000; // lea 0xff0000,a6
	ss_irq_handler[ 7] = 16'h2c8f;                                // move.l a7,(a6)
	ss_irq_handler[ 8] = 16'h2c5f;                                // move.l (a7)+,a6
	ss_irq_handler[ 9] = 16'h4e66;                                // move.l a6,usp
	ss_irq_handler[10] = 16'h4cdf; ss_irq_handler[11] = 16'h7fff; // movem.l (a7)+,d0-d7/a0-a6
	ss_irq_handler[12] = 16'h4e73;                                // rte
	ss_irq_handler[13] = 16'h0000;
	ss_irq_handler[14] = 16'h0000;
	ss_irq_handler[15] = 16'h0000;
end

reg [31:0] ss_saved_ssp;
reg [31:0] ss_restore_ssp;
reg [15:0] ss_reset_vector [0:3];

// Global state via ssbus: saves ss_saved_ssp (one 32-bit value), restores ss_restore_ssp.
always @(posedge clk) begin
	ss_glob.setup(SS_GLOB_IDX, 1, 2);  // 1 element, width 2 = 32 bits
	if (ss_glob.access(SS_GLOB_IDX)) begin
		if (ss_glob.read)  ss_glob.read_response(SS_GLOB_IDX, {32'd0, ss_saved_ssp});
		else if (ss_glob.write) begin
			ss_restore_ssp <= ss_glob.data[31:0];
			ss_glob.write_ack(SS_GLOB_IDX);
		end
	end
end

// ss_state FSM (F2.sv:208-385). WAIT_PAUSE (F2.sv:304-308,344-348): waits for paused_real (REAL
// frame-aligned pause = obj_paused of F2) BEFORE gather/scatter, so save/restore happen with
// CPU+audio truly stopped. paused_real = paused_safe_r registered at vblank (the combinational
// paused_safe would satisfy itself).
localparam [3:0]
	SST_IDLE              = 4'd0,
	SST_SAVE_WAIT_PAUSE   = 4'd8,  // waits for paused_real before the save (F2 SST_SAVE_WAIT_PAUSE)
	SST_SAVE_WAIT_IRQ     = 4'd1,  // waits for the level-7 IACK (the CPU takes the exception)
	SST_SAVE_WAIT_SSP     = 4'd2,  // captures the SSP written to SS_SCRATCH
	SST_SAVE_WAIT_WRITE   = 4'd3,  // memory_stream saves to DDR
	SST_SAVE_WAIT_EXIT    = 4'd4,  // waits for the handler's rte
	SST_RESTORE_WAIT_PAUSE= 4'd9,  // waits for paused_real before the restore (F2 SST_RESTORE_WAIT_PAUSE)
	SST_RESTORE_WAIT_READ = 4'd5,  // memory_stream loads from DDR
	SST_RESTORE_HOLD_RST  = 4'd6,  // holds reset for N cycles
	SST_RESTORE_WAIT_RST  = 4'd7;  // waits for the CPU restart

reg [3:0] ss_state = SST_IDLE;
reg [4:0] ss_reset_counter;
reg [3:0] ss_state_d;  // previous-cycle state, for ss_restore_done edge detection

// ss_override = during save/restore the CPU is "hijacked" (F2 ss_override).
// Address intercept (F2 address_translator.sv:69-87 + cpu_data_in F2.sv:1114-1116):
//   0xFF00xx -> SS_SAVEn=0  : the CPU executes ss_irq_handler[addr[4:1]]  (during save)
//   0x00007C/7E -> SS_VECn=0: level-7 autovector = 0x00FF0000 (handler PC)
//   0x00000x -> SS_RESETn=0 : custom reset vector (during restore)
wire ss_override = (ss_state != SST_IDLE);
wire ds_active   = ~&cpu_ds_n;  // at least one byte active

// Exact equivalents of the F2 chip selects (address_translator). "Active" range (= n low):
//   save  = 0xFF00xx (handler), reset = 0x00000x (reset vector).
wire ss_saven_n  = (cpu_word_addr[23:8] == 16'hFF00);   // 1 = in the save range (SS_SAVEn=0)
wire ss_resetn_n = (cpu_word_addr[23:4] == 20'h00000);  // 1 = in the reset range (SS_RESETn=0)

// ss_cpu_exec does NOT include WAIT_WRITE (F2: ss_cpu_execute=0 in SAVE_WAIT_WRITE): while
// memory_stream reads the work RAM the CPU must be STOPPED (consistent snapshot).
wire ss_save_active    = (ss_state == SST_SAVE_WAIT_IRQ) || (ss_state == SST_SAVE_WAIT_SSP) ||
                         (ss_state == SST_SAVE_WAIT_EXIT);
wire ss_restore_active = (ss_state == SST_RESTORE_HOLD_RST) || (ss_state == SST_RESTORE_WAIT_RST);

wire sel_save  = ss_override & ds_active & ss_saven_n;                          // SS_SAVEn
wire sel_vec   = ss_override & ds_active & (cpu_word_addr[23:2] == 22'h00001F); // 0x7C-0x7F -> SS_VECn
wire sel_rst   = ss_override & ds_active & ss_resetn_n;                         // SS_RESETn

assign ss_din_en   = sel_save | sel_vec | sel_rst;
assign ss_din_data = sel_save ? ss_irq_handler[cpu_word_addr[4:1]] :
                     sel_rst  ? ss_reset_vector[cpu_word_addr[2:1]] :
                     sel_vec  ? (cpu_word_addr[1] ? 16'h0000 : 16'h00FF) :  // exception PC = 0x00FF0000
                                16'h0000;

assign ss_irq      = (ss_state == SST_SAVE_WAIT_IRQ);
assign ss_reset    = (ss_state == SST_RESTORE_HOLD_RST);
assign ss_pause    = (ss_state != SST_IDLE);  // game stopped for the whole SS
assign ss_cpu_exec = ss_save_active | ss_restore_active;  // the CPU runs to execute handler/vector

always @(posedge clk) begin
	ss_state_d   <= ss_state;
	ss_state_out <= ss_state;
end

// Pulse ss_restore_done: transition SST_RESTORE_WAIT_RST -> SST_IDLE (restore complete, CPU
// restarted on normal code). The top uses it to restart the palette DMA and rebuild pal_buf
// from pal_cpu (already reloaded by memory_stream during the scatter).
assign ss_restore_done = (ss_state == SST_IDLE) && (ss_state_d == SST_RESTORE_WAIT_RST);

always @(posedge clk) begin
	ss_mem_write <= 1'b0;
	// ss_mem_read is NOT cleared by default: it is a level handled inside the restore states
	// (raised in WAIT_PAUSE, lowered in WAIT_READ on ss_busy) as in F2 (plain pulse, no auto-clear).

	case (ss_state)
		SST_IDLE: begin
			ss_mem_read <= 1'b0;   // clean level when idle (no global auto-clear, as F2 reg ss_read=0)
			if (do_save)    ss_state <= SST_SAVE_WAIT_PAUSE;
			if (do_restore) ss_state <= SST_RESTORE_WAIT_PAUSE;
		end

		// WAIT_PAUSE (F2): proceeds ONLY when paused_real=1 = real frame-aligned pause (CPU+audio
		// truly stopped). paused_real = paused_safe_r of the top (registered at vblank), NOT the
		// combinational paused_safe. It rises <=1 frame after ss_pause -> a REAL wait, not a no-op.
		SST_SAVE_WAIT_PAUSE: begin
			if (paused_real) ss_state <= SST_SAVE_WAIT_IRQ;
		end

		SST_RESTORE_WAIT_PAUSE: begin
			if (paused_real) begin
				ss_mem_read <= 1'b1;   // plain pulse as in F2 (F2.sv:346): raises read when entering WAIT_READ
				ss_state <= SST_RESTORE_WAIT_READ;
			end
		end

		// SAVE: forces IRQ7 (ss_irq). Waits for the level-7 IACK (the CPU acknowledges the exception).
		SST_SAVE_WAIT_IRQ: begin
			if (~iack_n & (cpu_word_addr[3:1] == 3'b111) & ~cpu_ds_n[0])
				ss_state <= SST_SAVE_WAIT_SSP;
		end

		// Captures the SSP that the handler writes to SS_SCRATCH (move.l a7,(a6) with a6=0xFF0000).
		SST_SAVE_WAIT_SSP: begin
			if (cpu_ds_n == 2'b00 && !cpu_rw && cpu_word_addr == SS_SCRATCH)
				ss_saved_ssp[31:16] <= cpu_data_out;
			if (cpu_ds_n == 2'b00 && !cpu_rw && cpu_word_addr == (SS_SCRATCH | 24'd2)) begin
				ss_saved_ssp[15:0] <= cpu_data_out;
				ss_mem_write <= 1'b1;
				ss_state <= SST_SAVE_WAIT_WRITE;
			end
		end

		// memory_stream saves the whole state to DDR.
		SST_SAVE_WAIT_WRITE: begin
			if (~ss_busy & ~ss_mem_write) ss_state <= SST_SAVE_WAIT_EXIT;
		end

		// Waits for the handler's rte and for the CPU to fetch NORMAL code again
		// (outside the save range 0xFF00xx, F2: && SS_SAVEn). != SS_SCRATCH is NOT enough: the CPU
		// still fetches the rest of the handler at 0xFF0008..0xFF001E before the rte.
		SST_SAVE_WAIT_EXIT: begin
			if (cpu_ds_n == 2'b00 && cpu_rw && cpu_fc == 3'b110 && ~ss_saven_n)
				ss_state <= SST_IDLE;
		end

		// RESTORE: memory_stream loads from DDR (reloads RAM + ss_restore_ssp via ssbus).
		// Plain pulse IDENTICAL to F2 (F2.sv:351-363): read raised in WAIT_PAUSE; here it is lowered
		// when memory_stream becomes busy, then the FSM advances when it has finished. No ss_read_done.
		SST_RESTORE_WAIT_READ: begin
			if (ss_busy & ss_mem_read) begin
				ss_mem_read <= 1'b0;
			end else if (~ss_busy & ~ss_mem_read & slot_empty) begin
				// Sub-slot never written: memory_stream applied NOTHING.
				// Going back to IDLE leaves the game intact; continuing would reset
				// the CPU with a reset vector from a stale state = game broken by
				// loading an empty slot.
				ss_state <= SST_IDLE;
			end else if (~ss_busy & ~ss_mem_read) begin
				ss_reset_vector[0] <= ss_restore_ssp[31:16];
				ss_reset_vector[1] <= ss_restore_ssp[15:0];
				ss_reset_vector[2] <= 16'h00FF;  // PC reset = 0x00FF0000 (handler restart point)
				ss_reset_vector[3] <= 16'h0008;
				ss_reset_counter <= 5'd0;
				ss_state <= SST_RESTORE_HOLD_RST;
			end
		end

		// Holds reset for N cycles (the CPU restarts from the custom reset vector).
		SST_RESTORE_HOLD_RST: begin
			if (ce_cpu) begin
				ss_reset_counter <= ss_reset_counter + 5'd1;
				if (&ss_reset_counter) ss_state <= SST_RESTORE_WAIT_RST;
			end
		end

		// Waits for the CPU to restart on NORMAL code: outside BOTH the save (0xFF00xx)
		// and reset (0x00000x) ranges, F2: && SS_SAVEn && SS_RESETn. The CPU restarts
		// from 0x00FF0008 (handler restart) and executes lea/movem/rte before returning to the game.
		SST_RESTORE_WAIT_RST: begin
			if (cpu_ds_n == 2'b00 && cpu_rw && cpu_fc == 3'b110 && ~ss_saven_n && ~ss_resetn_n)
				ss_state <= SST_IDLE;
		end

		default: ss_state <= SST_IDLE;
	endcase
end

endmodule
