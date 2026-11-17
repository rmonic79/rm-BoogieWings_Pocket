/*  This file is part of BoogieWings_MiSTer.
    GPL-3.
    Original author: Martin Donlon (wickerwaka) — Arcade-TaitoF2 savestate system.
    Modified/adapted for BoogieWings by: Umberto Parisi (rmonic79)
*/

//============================================================================
//  BoogieWings Savestate — core bus (ssbus)
//
//  Ported from the savestate system of Martin Donlon (wickerwaka), Arcade-TaitoF2.
//  Reference: savestates.sv of Arcade-TaitoF2.
//
//  ssbus_if  : interface bus. Every stateful module = slave with a unique SS_IDX.
//  ssbus_mux : multiplexes N slaves to 1 master (save_state_data).
//  auto_save_adaptor : wraps an N-bit register/signal and exposes it on the bus.
//
//  NB: the adaptors do NOT add BRAM (they are MUXes/service registers): this
//  matters because M10K blocks are scarce.
//============================================================================

`timescale 1ns / 1ps

interface ssbus_if();
    logic [63:0] data;
    logic [31:0] addr;
    logic [7:0]  select;
    logic        write;
    logic        read;
    logic        query;
    logic [63:0] data_out;
    logic        ack;

    // true when the bus is accessing THIS slave (read or write, not query)
    function logic access(int idx);
        return (select == idx[7:0]) & ~query & (read | write);
    endfunction

    // query phase: the slave declares how many words it has (count) and the width
    task setup(int idx, input [31:0] count, int width);
        ack <= 0;
        if (select == idx[7:0]) begin
            if (query) begin
                data_out <= { idx[7:0], 22'b0, width[1:0], count };
                ack <= 1;
            end
        end
    endtask

    task read_response(int idx, input [63:0] dout);
        if (select == idx[7:0]) begin
            data_out <= dout;
            ack <= 1;
        end
    endtask

    task write_ack(int idx);
        if (select == idx[7:0]) begin
            ack <= 1;
        end
    endtask

    modport master(
        output data, addr, select, write, read, query,
        input  data_out, ack
    );

    modport slave(
        input  data, addr, select, write, read, query,
        output data_out, ack,
        import access,
        import setup,
        import read_response,
        import write_ack
    );
endinterface


// Multiplexes COUNT slaves to one master. Combinational for the bus signals,
// registered for ack/data_out (OR of all the acks).
module ssbus_mux #(parameter COUNT = 4)(
    input clk,
    ssbus_if.master masters[COUNT],
    ssbus_if.slave  slave
);

logic [63:0] data_out[COUNT];
logic        ack[COUNT];

genvar gi;
generate
for (gi = 0; gi < COUNT; gi = gi + 1) begin: gen_loop
    always_comb begin
        ack[gi]      = masters[gi].ack;
        data_out[gi] = masters[gi].data_out;

        masters[gi].data   = slave.data;
        masters[gi].addr   = slave.addr;
        masters[gi].select = slave.select;
        masters[gi].write  = slave.write;
        masters[gi].read   = slave.read;
        masters[gi].query  = slave.query;
    end
end
endgenerate

int i;
always_ff @(posedge clk) begin
    slave.data_out <= 64'd0;
    slave.ack <= 0;

    for (i = 0; i < COUNT; i = i + 1) begin
        if (ack[i]) begin
            slave.ack <= 1;
            slave.data_out <= data_out[i];
        end
    end
end

endmodule


// auto_save_adaptor (at the end of this file): wraps an N-bit register/signal and
// exposes it on the ssbus in 16-bit words.
// save: the master reads all the words. load: it writes them back and raises bits_wr
// (pulse) when finished, so the target module reloads bits_out.
// DDR3 base for the 4 savestate slots (2MB/slot). Must match the base declared
// in the CONF_STR "SS<base>:<size>". For BoogieWings the core's DDR3 is at 0x30000000; the
// SS slots go in a HIGH area not used by the tile ROMs. 0x3E000000 = same as Taito F2.
// (the actual state is ~150KB << 2MB/slot).
`define SS_DDR_BASE_DEF 32'h3E000000

// Savestate master: drives memory_stream to DDR for slot `index`.
// COUNT = number of ssbus slaves (must match ssbus_mux #(.COUNT) in the top),
// otherwise memory_stream queries non-existent chunks and wastes query timeouts.
// STROBE_DLY (POCKET; the top sets it to 1): the read/write/query requests to the
// slaves rise one cycle AFTER memory_stream's and fall together with them. Address,
// data and select (which memory_stream changes only while the request is low) are
// thus stable for at least one cycle when a slave uses them: the Pocket SDC can give
// those paths 2 cycles. 0 = original behaviour.
module save_state_data #(parameter COUNT = 16, parameter STROBE_DLY = 0)(
    input clk,
    input reset,

    ddr_if.to_host ddr,

    input        read_start,
    input        write_start,
    input  [4:0] index,        // 32 slots: [4:3]=region (files .ss1-.ss4), [2:0]=sub-slot
    output       busy,
    output       slot_empty,   // load of a never-written sub-slot: apply nothing

    ssbus_if.master ssbus
);

// [32 SLOTS] The MiSTer Main firmware handles ONLY 4 slots of ss_size: process_ss
// (user_io.cpp) polls the change counters at base+i*ss_size (i=0..3) every ~1s,
// writes .ss1-.ss4 when they change and reloads the files into DDR at boot.
// For 32 persistent slots with a stock Main: 8 sub-slots per region.
// Region layout (2MB):
//   +0x00            : Main-facing region header {size_words[63:32], cnt[31:0]}
//   +0x10 + k*0x3F000: sub-slot k=0..7 (self-contained memory_stream image,
//                      own header + state ~165KB << 252KB)
//   8 * 0x3F000 = 0x1F8000, plus the header: within the 2MB with 32KB to spare.
// Save slot N: memory_stream writes the sub-slot; then the mini-FSM below
// updates the region header (cnt+1, size 0x7E002 words = payload from +8 to the end
// of sub-slot 7) -> THIS is what makes Main write the file: without an updated
// header the firmware notices nothing and the .ss is not saved.
// Load: direct read of the sub-slot (the files are already in DDR since boot).
wire [31:0] region_base = `SS_DDR_BASE_DEF + ({30'd0, index[4:3]} * 32'h00200000);
wire [31:0] sub_addr    = region_base + 32'h00000010 + ({29'd0, index[2:0]} * 32'h0003F000);

// internal ddr for memory_stream; mux below to the real ddr (never active
// together: the header FSM starts only after the stream has finished, busy stays high).
ddr_if ms_ddr();
wire ms_busy;

localparam H_IDLE=3'd0, H_RD=3'd1, H_RD_WAIT=3'd2, H_WR=3'd3, H_WR_WAIT=3'd4;
reg [2:0]  hstate = H_IDLE;
reg        hdr_pend = 0, saw_busy = 0;
reg [31:0] hdr_base;
reg [31:0] hdr_cnt;
reg        h_acquire = 0, h_read = 0, h_write = 0;
reg [31:0] h_addr;
reg [63:0] h_wdata;
wire       hdr_active = (hstate != H_IDLE);

always @(posedge clk) begin
    if (reset) begin
        hstate <= H_IDLE; hdr_pend <= 0; saw_busy <= 0;
        h_acquire <= 0; h_read <= 0; h_write <= 0;
    end else begin
        if (write_start) begin
            hdr_pend <= 1; saw_busy <= 0; hdr_base <= region_base;
        end
        if (hdr_pend && ms_busy) saw_busy <= 1;
        case (hstate)
            H_IDLE: if (hdr_pend && saw_busy && !ms_busy) begin
                hdr_pend  <= 0;
                h_acquire <= 1;
                hstate    <= H_RD;
            end
            H_RD: if (!ddr.busy) begin
                h_read <= 1; h_addr <= hdr_base;
                hstate <= H_RD_WAIT;
            end
            H_RD_WAIT: if (!ddr.busy) begin
                h_read <= 0;
                if (ddr.rdata_ready) begin
                    hdr_cnt <= ddr.rdata[31:0];
                    hstate  <= H_WR;
                end
            end
            H_WR: if (!ddr.busy) begin
                h_write <= 1; h_addr <= hdr_base;
                h_wdata <= {32'h0007E002, hdr_cnt + 32'd1};
                hstate  <= H_WR_WAIT;
            end
            H_WR_WAIT: if (!ddr.busy) begin
                h_write <= 0; h_acquire <= 0;
                hstate  <= H_IDLE;
            end
            default: hstate <= H_IDLE;
        endcase
    end
end

// mux to the real ddr
assign ddr.acquire    = hdr_active ? h_acquire : ms_ddr.acquire;
assign ddr.addr       = hdr_active ? h_addr    : ms_ddr.addr;
assign ddr.wdata      = hdr_active ? h_wdata   : ms_ddr.wdata;
assign ddr.read       = hdr_active ? h_read    : ms_ddr.read;
assign ddr.write      = hdr_active ? h_write   : ms_ddr.write;
assign ddr.burstcnt   = hdr_active ? 8'd1      : ms_ddr.burstcnt;
assign ddr.byteenable = hdr_active ? 8'hFF     : ms_ddr.byteenable;
assign ms_ddr.rdata       = ddr.rdata;
assign ms_ddr.busy        = ddr.busy;
assign ms_ddr.rdata_ready = ddr.rdata_ready;

assign busy = ms_busy | hdr_pend | hdr_active;

wire ms_read_req, ms_write_req, ms_query_req;
reg  ms_read_d = 0, ms_write_d = 0, ms_query_d = 0;
always @(posedge clk) begin
    ms_read_d  <= ms_read_req;
    ms_write_d <= ms_write_req;
    ms_query_d <= ms_query_req;
end
assign ssbus.read  = STROBE_DLY ? (ms_read_req  & ms_read_d)  : ms_read_req;
assign ssbus.write = STROBE_DLY ? (ms_write_req & ms_write_d) : ms_write_req;
assign ssbus.query = STROBE_DLY ? (ms_query_req & ms_query_d) : ms_query_req;

memory_stream #(.COUNT(COUNT)) memory_stream (
    .clk(clk),
    .reset(reset),

    .ddr(ms_ddr),

    .read_req(ms_read_req),
    .read_data(ssbus.data_out),
    .data_ack(ssbus.ack),

    .write_req(ms_write_req),
    .write_data(ssbus.data),

    .start_addr(sub_addr),
    .length(32'h0003F000),
    .read_start(read_start),
    .write_start(write_start),
    .busy(ms_busy),

    .chunk_select(ssbus.select),
    .chunk_address(ssbus.addr),
    .query_req(ms_query_req),
    .slot_empty(slot_empty)
);

endmodule


module auto_save_adaptor #(parameter N_BITS = 16, SS_IDX = -1)(
    input clk,

    ssbus_if.slave ssbus,

    input  [N_BITS-1:0] bits_in,
    output [N_BITS-1:0] bits_out,
    output reg          bits_wr
);

localparam N_WORDS = (N_BITS + 15) / 16;

reg [(N_WORDS * 16) - 1:0] storage;
reg [(N_WORDS * 16) - 1:0] storage1;

assign bits_out = storage[N_BITS-1:0];

always @(posedge clk) begin
    storage1[N_BITS-1:0] <= bits_in;
    bits_wr <= 0;
    ssbus.setup(SS_IDX, N_WORDS + 1, 1);

    if (ssbus.access(SS_IDX)) begin
        if (ssbus.write) begin
            if (ssbus.addr == N_WORDS) begin
                bits_wr <= 1;
            end else begin
                storage[ ssbus.addr * 16 +: 16 ] <= ssbus.data[15:0];
            end
            ssbus.write_ack(SS_IDX);
        end else if (ssbus.read) begin
            ssbus.read_response(SS_IDX, {48'd0, storage1[ ssbus.addr * 16 +: 16 ] });
        end
    end
end

endmodule
