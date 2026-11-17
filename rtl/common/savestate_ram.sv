/*  This file is part of BoogieWings_MiSTer.
    GPL-3.
    Original author: Martin Donlon (wickerwaka) — Arcade-TaitoF2 savestate system.
    Modified/adapted for BoogieWings by: Umberto Parisi (rmonic79)
*/

//============================================================================
//  BoogieWings Savestate — adaptor for the inline-inferred RAMs
//
//  The Boogie Wings RAMs are `reg [7:0] mem[0:N]` with the CPU port split into
//  bytes (lo/hi). The adaptor sits IN SERIES on the port lines:
//  in normal mode it passes the game signals through; when the ssbus accesses
//  SS_IDX, it redirects the port to the savestate bus (read/write).
//  It adds NO BRAM.
//
//  Based on ram.sv of the Arcade-TaitoF2 savestate system (ram_ss_adaptor /
//  m68k_ram_ss_adaptor).
//
//  "Byte-pair" variant (lo+hi as 16 bits, word address) for the typical
//  Boogie Wings 68K RAMs: ram_lo/ram_hi, pf*_vram_lo/hi, sprite, palette, mirror.
//============================================================================

`timescale 1ns / 1ps

// Adaptor for a pair of byte BRAMs (lo+hi) addressed by word.
// WIDTHAD = word address bits (e.g. 15 for 32K words, 12 for 4K words).
// Exposes a 16-bit R/W port on the ssbus; reads use the BRAM q (= {q_hi,q_lo}).
//
// Usage: connect the game's we_lo/we_hi/addr/wdata to the _in ports; the _out ports go to the BRAM.
// q_in = data read from the BRAM at addr_out (1-clock latency → read_delay).
module ss_ram16_adaptor #(
    parameter WIDTHAD = 15,
    parameter SS_IDX  = -1
) (
    input                    clk,

    // game side (in)
    input                    we_lo_in,
    input                    we_hi_in,
    input      [WIDTHAD-1:0] addr_in,
    input      [15:0]        wdata_in,

    // BRAM side (out)
    output                   we_lo_out,
    output                   we_hi_out,
    output     [WIDTHAD-1:0] addr_out,
    output     [15:0]        wdata_out,

    // data read from the BRAM (q_hi,q_lo) at addr_out
    input      [15:0]        q_in,

    ssbus_if.slave           ssbus
);

wire sel = ssbus.access(SS_IDX);

assign addr_out  = sel ? ssbus.addr[WIDTHAD-1:0] : addr_in;
assign wdata_out = sel ? ssbus.data[15:0]        : wdata_in;
assign we_lo_out = sel ? ssbus.write             : we_lo_in;
assign we_hi_out = sel ? ssbus.write             : we_hi_in;

wire [31:0] SIZE = 32'd1 << WIDTHAD;

reg read_delay;
always @(posedge clk) begin
    ssbus.setup(SS_IDX, SIZE, 1);  // width 1 = 16 bit

    if (ssbus.access(SS_IDX)) begin
        if (ssbus.write) begin
            ssbus.write_ack(SS_IDX);
        end else if (ssbus.read) begin
            if (read_delay) begin
                ssbus.read_response(SS_IDX, {48'd0, q_in});
            end
            read_delay <= 1;
        end
    end else begin
        read_delay <= 0;
    end
end

endmodule
