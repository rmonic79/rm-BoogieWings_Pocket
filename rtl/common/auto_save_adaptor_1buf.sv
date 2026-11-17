// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) Umberto Parisi (rmonic79).
//
// auto_save_adaptor_1buf — POCKET. Same ssbus slave as auto_save_adaptor but with
// ONE N_BITS buffer instead of two (storage for the load + storage1 for the save
// capture): half the registers.
//
//   - capture: buf <= bits_in every cycle (like storage1), except during a load;
//   - load: the written words go into buf (capture suspended from the first word);
//     the write to address N_WORDS is the commit (bits_wr, as in the original);
//     capture resumes only when the commit access has finished, because the
//     master holds the write for several cycles and there is a bits_wr on every
//     cycle: all of them must see the loaded data (like storage in the original);
//   - save: response from buf, i.e. bits_in of the previous cycle (like storage1).
//
// Registered request (timing on the Pocket): memory_stream changes the address and
// raises the request in the same cycle; here address, data and request first go
// through a register and the write/response happens the next cycle from stable
// values (address decode over 177 words kept off the bus path). The master waits
// for the ack, so one extra cycle of latency does not change what is saved or
// loaded; the ack is given only while the request is still active, so the delay
// between end of request and end of ack stays the same as in the original.
//
// Equivalent to the original for a module that uses bits_out ONLY in bits_wr
// cycles (as jt51 does) and with the memory_stream protocol (all the words of a
// block written, in order, then the commit).
//

module auto_save_adaptor_1buf #(parameter N_BITS = 16, SS_IDX = -1)(
    input clk,
    ssbus_if.slave ssbus,
    input  [N_BITS-1:0] bits_in,
    output [N_BITS-1:0] bits_out,
    output reg          bits_wr
);

localparam N_WORDS = (N_BITS + 15) / 16;

reg [(N_WORDS * 16) - 1:0] buffer;
reg loading = 0;      // load in progress: capture suspended
reg committed = 0;    // commit seen: capture resumes at the end of the access
assign bits_out = buffer[N_BITS-1:0];

// stage 1: registered request
reg        acc_r = 0, wr_r = 0, rd_r = 0;
reg [31:0] addr_r = 0;
reg [15:0] data_r = 0;

always @(posedge clk) begin
    acc_r  <= ssbus.access(SS_IDX);
    wr_r   <= ssbus.write;
    rd_r   <= ssbus.read;
    addr_r <= ssbus.addr;
    data_r <= ssbus.data[15:0];
end

// stage 2: write / response from the registered values
always @(posedge clk) begin
    if (!loading) buffer[N_BITS-1:0] <= bits_in;
    bits_wr <= 0;
    ssbus.setup(SS_IDX, N_WORDS + 1, 1);
    if (acc_r) begin
        // the ack is given only if the request is STILL active: once the master
        // has dropped it there is no response, as in the original (a late ack
        // would reach memory_stream while it waits for the next block's query).
        if (wr_r) begin
            if (addr_r == N_WORDS) begin
                bits_wr   <= 1;
                committed <= 1;
            end else begin
                buffer[ addr_r * 16 +: 16 ] <= data_r;
                loading <= 1;
            end
            if (ssbus.access(SS_IDX) && ssbus.write) ssbus.write_ack(SS_IDX);
        end else if (rd_r) begin
            if (ssbus.access(SS_IDX) && ssbus.read)
                ssbus.read_response(SS_IDX, {48'd0, buffer[ addr_r * 16 +: 16 ] });
        end
    end else if (committed) begin
        loading   <= 0;
        committed <= 0;
    end
end

endmodule
