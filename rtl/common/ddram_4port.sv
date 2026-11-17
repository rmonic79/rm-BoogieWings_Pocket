//
// ddram.v
// Copyright (c) 2017 Sorgelig
//
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version. 
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
// ------------------------------------------
//

// 8-bit version

module ddram_4port
(
	input         DDRAM_CLK,

	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	input  [27:0] wraddr,
	input  [15:0] din,
	input         we_byte,  // 0:word write, 1:byte write
	input         we_req,
	output reg    we_ack = 0,

	input     [27:0] rdaddr,
	output reg [7:0] dout = 0,
	input            rd_req,
	output reg       rd_ack = 0,

	input     [27:0] rdaddr2,
	output reg [7:0] dout2 = 0,
	input            rd_req2,
	output reg       rd_ack2 = 0,

	input     [27:0] rdaddr3,
	output reg [7:0] dout3 = 0,
	input            rd_req3,
	output reg       rd_ack3 = 0,

	// Port 4: dedicated 32-bit fetch (sprite ROM)
	// Unlike ports 1-3 (8-bit), to avoid 4× round trips per sprite row.
	// 8-byte cache like the others, but dout4 exposes 32 bits selected by rdaddr4[2].
	input     [27:0] rdaddr4,
	output reg [31:0] dout4 = 0,
	input            rd_req4,
	output reg       rd_ack4 = 0,

	// Port 5: dedicated 32-bit fetch (OKI0 ADPCM samples, wired in boogwings_top).
	// PRIORITY over the sprites (see state 0): hard-real-time path without retry.
	input     [27:0] rdaddr5,
	output reg [31:0] dout5 = 0,
	input            rd_req5,
	output reg       rd_ack5 = 0,

	// Port 6: dedicated 32-bit fetch (OKI1 ADPCM samples, like port 5).
	input     [27:0] rdaddr6,
	output reg [31:0] dout6 = 0,
	input            rd_req6,
	output reg       rd_ack6 = 0,

	// Port 7: dedicated 32-bit fetch (BG2 chip1.pf2; tied off in boogwings_top, BG2 is in SDRAM).
	input     [27:0] rdaddr7,
	output reg [31:0] dout7 = 0,
	input            rd_req7,
	output reg       rd_ack7 = 0,

	// Port 8: dedicated 32-bit fetch (text chip0.pf1; tied off in boogwings_top, text is in SDRAM).
	input     [27:0] rdaddr8,
	output reg [31:0] dout8 = 0,
	input            rd_req8,
	output reg       rd_ack8 = 0,

	// Port 9: dedicated 32-bit fetch (sprite2 chip1 sprites2 ROM, BoogieWings).
	input     [27:0] rdaddr9,
	output reg [31:0] dout9 = 0,
	input            rd_req9,
	output reg       rd_ack9 = 0,

	input     [27:0] cpaddr,
	output reg[63:0] cpdout,
	output reg       cpwr,
	input            cpreq,
	output reg       cpbusy,

	// Savestate quiescence: 1 = arbiter idle (state 0, no DDR transaction in flight,
	// all rd_ack == rd_req). Not used by ss_ddr_gate, which drains the bus with its own logic.
	output wire      ss_idle,
	// Savestate hold: 1 = the savestate owns the DDR bus. The arbiter issues NO new transactions
	// (stays in state 0); client requests stay pending and are served when ss_hold falls.
	// Avoids lost reads / a hung FSM when the MUX routes DDRAM_* to the savestate.
	input  wire      ss_hold
);

reg  [7:0] ram_burst;
reg [63:0] ram_q, next_q, ram_q2, next_q2, ram_q3, next_q3, ram_q4, next_q4, ram_q5, next_q5, ram_q6, next_q6, ram_q7, next_q7, ram_q8, next_q8, ram_q9, next_q9;
reg [63:0] ram_data;
reg [27:0] ram_address;
// cache_addr* initialised to '1 (all ones) so the first cache compare ALWAYS fails
// and forces a real fetch from DDRAM. Without this init, at power-up cache_addr=0 and
// rdaddr=0 → false match → a CPU client reads ram_q=0 (8 NOPs on a Z80) instead of the ROM.
reg [27:0] cache_addr  = '1;
reg [27:0] cache_addr2 = '1;
reg [27:0] cache_addr3 = '1;
reg [27:0] cache_addr4 = '1;
reg [27:0] cache_addr5 = '1;
reg [27:0] cache_addr6 = '1;
reg [27:0] cache_addr7 = '1;
reg [27:0] cache_addr8 = '1;
reg [27:0] cache_addr9 = '1;
reg        ram_read = 0;
reg        ram_write = 0;
reg  [7:0] ram_wr_be;

reg [2:0]  state  = 0;
reg [3:0]  ch = 0;

assign DDRAM_BURSTCNT = ram_burst;
assign DDRAM_BE       = ram_wr_be | {8{ram_read}};
assign DDRAM_ADDR     = {4'b0011, ram_address[27:3]}; // RAM at 0x30000000
assign DDRAM_RD       = ram_read;
assign DDRAM_DIN      = ram_data;
assign DDRAM_WE       = ram_write;

// Savestate quiescence: arbiter idle = FSM in state 0, no DDR transaction issued
// (~ram_read & ~ram_write), no pending client request (rd_ack==rd_req for all the
// active ports), no pending write (we_ack==we_req). ss_idle=1 means a DDRAM MUX can
// switch to the savestate without losing/corrupting in-flight transactions.
assign ss_idle = (state == 3'd0) & ~ram_read & ~ram_write & ~DDRAM_BUSY
               & (we_ack  == we_req)
               & (rd_ack  == rd_req)  & (rd_ack2 == rd_req2) & (rd_ack3 == rd_req3)
               & (rd_ack4 == rd_req4) & (rd_ack5 == rd_req5) & (rd_ack6 == rd_req6)
               & (rd_ack7 == rd_req7) & (rd_ack8 == rd_req8) & (rd_ack9 == rd_req9);

always @(posedge DDRAM_CLK) begin
	reg old_cpreq;
	reg [6:0] cpcnt;

	cpwr <= 0;
	if(!DDRAM_BUSY) begin
		ram_write <= 0;
		ram_read  <= 0;

		case(state)
			0: if(ss_hold) begin
					// the savestate owns the bus: issue no new transactions, wait.
					ram_write <= 0;
					ram_read  <= 0;
				end
				else if(we_ack != we_req) begin
					ram_data	<= we_byte ? {8{din[7:0]}} : {4{din}};
					ram_address <= wraddr;
					ram_write 	<= 1;
					ram_burst   <= 1;
					ram_wr_be   <= we_byte ? (8'd1<<{wraddr[2:0]}) : (8'd3<<{wraddr[2:1],1'b0});
					state       <= 1;
				end
				else if(rd_req != rd_ack) begin
					if(cache_addr[27:3] == rdaddr[27:3]) begin
						rd_ack      <= rd_req;
						dout        <= ram_q[{rdaddr[2:0],3'b000} +:8];
					end
					else if((cache_addr[27:3]+1'd1) == rdaddr[27:3]) begin
						rd_ack      <= rd_req;
						ram_q       <= next_q;
						dout        <= next_q[{rdaddr[2:0],3'b000} +:8];
						cache_addr  <= {rdaddr[27:3],3'b000};
						ram_address <= {rdaddr[27:3]+1'd1,3'b000};
						ram_read    <= 1;
						ram_burst   <= 1;
						ch 			<= 0; 
						state       <= 3;
					end
					else begin
						ram_address <= {rdaddr[27:3],3'b000};
						cache_addr  <= {rdaddr[27:3],3'b000};
						ram_read    <= 1;
						ram_burst   <= 2;
						ch 			<= 0; 
						state       <= 2;
					end 
				end
				else if(rd_req2 != rd_ack2) begin
					if(cache_addr2[27:3] == rdaddr2[27:3]) begin
						rd_ack2     <= rd_req2;
						dout2       <= ram_q2[{rdaddr2[2:0],3'b000} +:8];
					end
					else if((cache_addr2[27:3]+1'd1) == rdaddr2[27:3]) begin
						rd_ack2     <= rd_req2;
						ram_q2      <= next_q2;
						dout2       <= next_q2[{rdaddr2[2:0],3'b000} +:8];
						cache_addr2 <= {rdaddr2[27:3],3'b000};
						ram_address <= {rdaddr2[27:3]+1'd1,3'b000};
						ram_read    <= 1;
						ram_burst   <= 1;
						ch 			<= 1;
						state       <= 3;
					end
					else begin
						ram_address <= {rdaddr2[27:3],3'b000};
						cache_addr2 <= {rdaddr2[27:3],3'b000};
						ram_read    <= 1;
						ram_burst   <= 2;
						ch 			<= 1;
						state       <= 2;
					end 
				end 
				else if(rd_req3 != rd_ack3) begin
					if(cache_addr3[27:3] == rdaddr3[27:3]) begin
						rd_ack3     <= rd_req3;
						dout3       <= ram_q3[{rdaddr3[2:0],3'b000} +:8];
					end
					else if((cache_addr3[27:3]+1'd1) == rdaddr3[27:3]) begin
						rd_ack3     <= rd_req3;
						ram_q3      <= next_q3;
						dout3       <= next_q3[{rdaddr3[2:0],3'b000} +:8];
						cache_addr3 <= {rdaddr3[27:3],3'b000};
						ram_address <= {rdaddr3[27:3]+1'd1,3'b000};
						ram_read    <= 1;
						ram_burst   <= 1;
						ch 			<= 3'd2;
						state       <= 3;
					end
					else begin
						ram_address <= {rdaddr3[27:3],3'b000};
						cache_addr3 <= {rdaddr3[27:3],3'b000};
						ram_read    <= 1;
						ram_burst   <= 2;
						ch 			<= 3'd2;
						state       <= 2;
					end
				end
				else if(rd_req5 != rd_ack5) begin
					// Ports 5 (OKI0) and 6 (OKI1) BEFORE port 4 (sprites): the jt6295 ADPCM
					// path is hard real-time (deadline ~760/384 clk per slot) while the sprite
					// path has a handshake and tolerates queuing. With the sprites ahead in the
					// fixed priority, a burst of sprite misses postpones the OKIs without bound
					// -> stale byte = audio glitch. OKI bandwidth is negligible
					// (<=16 fetches/132us): the sprites lose at most ~4 services per period.
					if(cache_addr5[27:3] == rdaddr5[27:3]) begin
						rd_ack5     <= rd_req5;
						dout5       <= ram_q5[{rdaddr5[2],5'b00000} +:32];
					end
					else if((cache_addr5[27:3]+1'd1) == rdaddr5[27:3]) begin
						rd_ack5     <= rd_req5;
						ram_q5      <= next_q5;
						dout5       <= next_q5[{rdaddr5[2],5'b00000} +:32];
						cache_addr5 <= {rdaddr5[27:3],3'b000};
						ram_address <= {rdaddr5[27:3]+1'd1,3'b000};
						ram_read    <= 1;
						ram_burst   <= 1;
						ch 			<= 4'd4;
						state       <= 3;
					end
					else begin
						ram_address <= {rdaddr5[27:3],3'b000};
						cache_addr5 <= {rdaddr5[27:3],3'b000};
						ram_read    <= 1;
						ram_burst   <= 2;
						ch 			<= 4'd4;
						state       <= 2;
					end
				end
				else if(rd_req6 != rd_ack6) begin
					// Port 6: OKI1 (same priority over the sprites as port 5)
					if(cache_addr6[27:3] == rdaddr6[27:3]) begin
						rd_ack6     <= rd_req6;
						dout6       <= ram_q6[{rdaddr6[2],5'b00000} +:32];
					end
					else if((cache_addr6[27:3]+1'd1) == rdaddr6[27:3]) begin
						rd_ack6     <= rd_req6;
						ram_q6      <= next_q6;
						dout6       <= next_q6[{rdaddr6[2],5'b00000} +:32];
						cache_addr6 <= {rdaddr6[27:3],3'b000};
						ram_address <= {rdaddr6[27:3]+1'd1,3'b000};
						ram_read    <= 1;
						ram_burst   <= 1;
						ch 			<= 4'd5;
						state       <= 3;
					end
					else begin
						ram_address <= {rdaddr6[27:3],3'b000};
						cache_addr6 <= {rdaddr6[27:3],3'b000};
						ram_read    <= 1;
						ram_burst   <= 2;
						ch 			<= 4'd5;
						state       <= 2;
					end
				end
				else if(rd_req4 != rd_ack4) begin
					// Port 4 (sprite ROM): AFTER the OKIs (see the comment at port 5)
					if(cache_addr4[27:3] == rdaddr4[27:3]) begin
						rd_ack4     <= rd_req4;
						dout4       <= ram_q4[{rdaddr4[2],5'b00000} +:32];
					end
					else if((cache_addr4[27:3]+1'd1) == rdaddr4[27:3]) begin
						rd_ack4     <= rd_req4;
						ram_q4      <= next_q4;
						dout4       <= next_q4[{rdaddr4[2],5'b00000} +:32];
						cache_addr4 <= {rdaddr4[27:3],3'b000};
						ram_address <= {rdaddr4[27:3]+1'd1,3'b000};
						ram_read    <= 1;
						ram_burst   <= 1;
						ch 			<= 3'd3;
						state       <= 3;
					end
					else begin
						ram_address <= {rdaddr4[27:3],3'b000};
						cache_addr4 <= {rdaddr4[27:3],3'b000};
						ram_read    <= 1;
						ram_burst   <= 2;
						ch 			<= 3'd3;
						state       <= 2;
					end
				end
				else if(rd_req7 != rd_ack7) begin
					// Port 7: 32-bit fetch BG2 chip1.pf2
					if(cache_addr7[27:3] == rdaddr7[27:3]) begin
						rd_ack7     <= rd_req7;
						dout7       <= ram_q7[{rdaddr7[2],5'b00000} +:32];
					end
					else if((cache_addr7[27:3]+1'd1) == rdaddr7[27:3]) begin
						rd_ack7     <= rd_req7;
						ram_q7      <= next_q7;
						dout7       <= next_q7[{rdaddr7[2],5'b00000} +:32];
						cache_addr7 <= {rdaddr7[27:3],3'b000};
						ram_address <= {rdaddr7[27:3]+1'd1,3'b000};
						ram_read    <= 1;
						ram_burst   <= 1;
						ch 			<= 4'd6;
						state       <= 3;
					end
					else begin
						ram_address <= {rdaddr7[27:3],3'b000};
						cache_addr7 <= {rdaddr7[27:3],3'b000};
						ram_read    <= 1;
						ram_burst   <= 2;
						ch 			<= 4'd6;
						state       <= 2;
					end
				end
				else if(rd_req8 != rd_ack8) begin
					// Port 8: 32-bit fetch text chip0.pf1
					if(cache_addr8[27:3] == rdaddr8[27:3]) begin
						rd_ack8     <= rd_req8;
						dout8       <= ram_q8[{rdaddr8[2],5'b00000} +:32];
					end
					else if((cache_addr8[27:3]+1'd1) == rdaddr8[27:3]) begin
						rd_ack8     <= rd_req8;
						ram_q8      <= next_q8;
						dout8       <= next_q8[{rdaddr8[2],5'b00000} +:32];
						cache_addr8 <= {rdaddr8[27:3],3'b000};
						ram_address <= {rdaddr8[27:3]+1'd1,3'b000};
						ram_read    <= 1;
						ram_burst   <= 1;
						ch 			<= 4'd7;
						state       <= 3;
					end
					else begin
						ram_address <= {rdaddr8[27:3],3'b000};
						cache_addr8 <= {rdaddr8[27:3],3'b000};
						ram_read    <= 1;
						ram_burst   <= 2;
						ch 			<= 4'd7;
						state       <= 2;
					end
				end
				else if(rd_req9 != rd_ack9) begin
					// Port 9: 32-bit fetch sprites2 chip1 ROM
					if(cache_addr9[27:3] == rdaddr9[27:3]) begin
						rd_ack9     <= rd_req9;
						dout9       <= ram_q9[{rdaddr9[2],5'b00000} +:32];
					end
					else if((cache_addr9[27:3]+1'd1) == rdaddr9[27:3]) begin
						rd_ack9     <= rd_req9;
						ram_q9      <= next_q9;
						dout9       <= next_q9[{rdaddr9[2],5'b00000} +:32];
						cache_addr9 <= {rdaddr9[27:3],3'b000};
						ram_address <= {rdaddr9[27:3]+1'd1,3'b000};
						ram_read    <= 1;
						ram_burst   <= 1;
						ch 			<= 4'd8;
						state       <= 3;
					end
					else begin
						ram_address <= {rdaddr9[27:3],3'b000};
						cache_addr9 <= {rdaddr9[27:3],3'b000};
						ram_read    <= 1;
						ram_burst   <= 2;
						ch 			<= 4'd8;
						state       <= 2;
					end
				end else begin
					cpbusy         <= 0;
					old_cpreq <= cpreq;
					if(~old_cpreq & cpreq) begin
						ram_address <= {cpaddr[27:3],3'b000};
						ram_burst   <= 128;
						ram_read    <= 1;
						state       <= 4;
						cpcnt       <= 127;
						cpbusy      <= 1;
					end
				end

			1: begin
					cache_addr <= '1;
					cache_addr2 <= '1;
					cache_addr3 <= '1;
					cache_addr4 <= '1;
					cache_addr5 <= '1;
					cache_addr6 <= '1;
					cache_addr7 <= '1;
					cache_addr8 <= '1;
					cache_addr9 <= '1;
					cache_addr[3:0] <= 0;
					cache_addr2[3:0] <= 0;
					cache_addr3[3:0] <= 0;
					cache_addr4[3:0] <= 0;
					cache_addr5[3:0] <= 0;
					cache_addr6[3:0] <= 0;
					cache_addr7[3:0] <= 0;
					cache_addr8[3:0] <= 0;
					cache_addr9[3:0] <= 0;
					we_ack <= we_req;
					state  <= 0;
				end

			2: if(DDRAM_DOUT_READY) begin
					if (ch==4'd0) begin
						ram_q  <= DDRAM_DOUT;
						dout   <= DDRAM_DOUT[{rdaddr[2:0],3'b000} +:8];
						rd_ack <= rd_req;
					end
					else if (ch==4'd1) begin
						ram_q2  <= DDRAM_DOUT;
						dout2   <= DDRAM_DOUT[{rdaddr2[2:0],3'b000} +:8];
						rd_ack2 <= rd_req2;
					end
					else if (ch==4'd2) begin
						ram_q3  <= DDRAM_DOUT;
						dout3   <= DDRAM_DOUT[{rdaddr3[2:0],3'b000} +:8];
						rd_ack3 <= rd_req3;
					end
					else if (ch==4'd3) begin
						ram_q4  <= DDRAM_DOUT;
						dout4   <= DDRAM_DOUT[{rdaddr4[2],5'b00000} +:32];
						rd_ack4 <= rd_req4;
					end
					else if (ch==4'd4) begin
						ram_q5  <= DDRAM_DOUT;
						dout5   <= DDRAM_DOUT[{rdaddr5[2],5'b00000} +:32];
						rd_ack5 <= rd_req5;
					end
					else if (ch==4'd5) begin
						ram_q6  <= DDRAM_DOUT;
						dout6   <= DDRAM_DOUT[{rdaddr6[2],5'b00000} +:32];
						rd_ack6 <= rd_req6;
					end
					else if (ch==4'd6) begin
						ram_q7  <= DDRAM_DOUT;
						dout7   <= DDRAM_DOUT[{rdaddr7[2],5'b00000} +:32];
						rd_ack7 <= rd_req7;
					end
					else if (ch==4'd7) begin
						ram_q8  <= DDRAM_DOUT;
						dout8   <= DDRAM_DOUT[{rdaddr8[2],5'b00000} +:32];
						rd_ack8 <= rd_req8;
					end
					else begin  // ch==4'd8
						ram_q9  <= DDRAM_DOUT;
						dout9   <= DDRAM_DOUT[{rdaddr9[2],5'b00000} +:32];
						rd_ack9 <= rd_req9;
					end
					state  <= 3;
				end

			3: if(DDRAM_DOUT_READY) begin
					if (ch==4'd0) begin
						next_q <= DDRAM_DOUT;
					end
					else if (ch==4'd1) begin
						next_q2 <= DDRAM_DOUT;
					end
					else if (ch==4'd2) begin
						next_q3 <= DDRAM_DOUT;
					end
					else if (ch==4'd3) begin
						next_q4 <= DDRAM_DOUT;
					end
					else if (ch==4'd4) begin
						next_q5 <= DDRAM_DOUT;
					end
					else if (ch==4'd5) begin
						next_q6 <= DDRAM_DOUT;
					end
					else if (ch==4'd6) begin
						next_q7 <= DDRAM_DOUT;
					end
					else if (ch==4'd7) begin
						next_q8 <= DDRAM_DOUT;
					end
					else begin  // ch==4'd8
						next_q9 <= DDRAM_DOUT;
					end
					state  <= 0;
				end

			4: if(DDRAM_DOUT_READY) begin
					cpwr   <= 1;
					cpcnt  <= cpcnt - 1'd1;
					cpdout <= DDRAM_DOUT;
					if(!cpcnt) state <= 0;
				end
		endcase
	end
end

endmodule
