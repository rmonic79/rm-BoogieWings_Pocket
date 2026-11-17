/*  This file is part of JT6295.
    JT6295 program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT6295 program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT6295.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 6-1-2020 */
// Modified for BoogieWings (savestate, ROM address stability): Umberto Parisi (rmonic79)

// Each sampling period is divided into 4 regions, one per channel
// each region is further divided into 8 time slots for memory access
// of those, 2 are used for ADPCM data. Those 2 are in the middle of
// the region, so data will be ready for next cen4 pulse. No adpcm_ok
// signal is generated. Data is assumed to be right after two cen32 pulses
// 
// The other 6 regions are used for control data. Ok signals are generated
// and use to gate the progress of the control state machine

module jt6295_rom(
    input             rst,
    input             clk,
    input             cen4,
    input             cen32,

    input      [17:0] adpcm_addr,
    input      [17:0] ctrl_addr,

    output reg [ 7:0] adpcm_dout,
    output reg [ 7:0] ctrl_dout,

    output reg        ctrl_ok,
    // ROM interface
    output reg [17:0] rom_addr,
    input      [ 7:0] rom_data,
    input             rom_ok,
    // Savestate (Taito F2 pattern): on restore (pulse) clears ctrl_ok/wait2 — they are REGISTERED
    // flags that would survive the invalidation of the external ROM cache by 1 clk, and the ctrl
    // FSM (full clk, no cen) would make ONE spurious advance with stale rom_data. auto_ss_wr=0 -> inert.
    input             auto_ss_wr
);

reg [7:0] st;
reg [1:0] wait2;
reg [1:0] await;   // address stability in the ADPCM slots (like wait2 for ctrl)

always @(posedge clk) begin
    if(cen4 ) st <= 8'h80;
    else if(cen32) st <= { st[6:0], st[7] };
end

wire new_addr = rom_addr != ctrl_addr;

always @(posedge clk) begin
    case(st)
        8'b1,8'b10: begin
            rom_addr   <= adpcm_addr;
            // HARDENING (robustness across fits): latch ONLY with the address stable for
            // >=2 clk and rom_ok (the original latches blindly every clk, "data assumed
            // right after two cen32 pulses"). If the data does not arrive by the deadline
            // the PREVIOUS byte is kept (repeated sample, almost inaudible) instead of a
            // byte from the wrong stream, which would make the ADPCM predictor diverge
            // (glitch). In steady state (cache hit) the value latched at the end of the
            // slot is the same as in the original: only the failure case changes.
            if(await==2'b11 && rom_addr == adpcm_addr && rom_ok)
                adpcm_dout <= rom_data;
            await      <= (rom_addr != adpcm_addr) ? 2'b0 : {await[0],1'b1};
            ctrl_ok    <= 1'b0;
            wait2      <= 2'b0;
        end
        default: begin
            rom_addr   <= ctrl_addr;
            // right after coming in rom_ok will still
            // represent the status for adpcm data
            if(wait2==2'b11 && !new_addr) begin
                ctrl_ok   <= rom_ok;
                ctrl_dout <= rom_data;
            end else ctrl_ok <= 1'b0;
            if( new_addr )
                wait2 <= 2'b0;
            else
                wait2 <= {wait2[0],1'b1};
            await <= 2'b0;   // outside the ADPCM slots the window restarts from zero
        end
    endcase
    // restore: last statement = priority. A ctrl_ok already latched by the pre-restore cycle
    // is cleared; wait2=0 requires >=3 clk of stable address before trusting rom_ok again
    // (by then the external cache is invalidated -> rom_ok=0 -> FSM stopped until resume).
    if( auto_ss_wr ) begin
        ctrl_ok <= 1'b0;
        wait2   <= 2'b0;
        await   <= 2'b0;   // symmetric: no ADPCM latch with pre-restore data
    end
end

endmodule