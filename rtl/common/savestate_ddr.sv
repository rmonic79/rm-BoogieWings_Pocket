/*  This file is part of BoogieWings_MiSTer.
    GPL-3.
    Original author: Martin Donlon (wickerwaka) — Arcade-TaitoF2 savestate system.
    Modified/adapted for BoogieWings by: Umberto Parisi (rmonic79)
*/

//============================================================================
//  BoogieWings Savestate — ddr_if interface
//  Ported from ddram.sv of the Arcade-TaitoF2 savestate system (Martin Donlon).
//  ddr_if maps 1:1 onto the MiSTer DDRAM_* signals.
//  NB: the original ddr_mux is not used — in Boogie Wings the DDR mux is written
//  by hand in the top level (gated on ss_busy). Only the ddr_if interface is needed here.
//============================================================================

interface ddr_if;
    logic        acquire;

    logic [31:0] addr;
    logic [63:0] wdata;
    logic [63:0] rdata;
    logic        read;
    logic        write;
    logic  [7:0] burstcnt;
    logic  [7:0] byteenable;
    logic        busy;
    logic        rdata_ready;

    modport to_host(
        output addr, wdata, read, write, burstcnt, byteenable, acquire,
        input rdata, busy, rdata_ready
    );

    modport from_host(
        output rdata, busy, rdata_ready,
        input addr, wdata, read, write, burstcnt, byteenable, acquire
    );


endinterface


