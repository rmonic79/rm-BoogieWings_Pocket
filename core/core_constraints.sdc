#
# core_constraints.sdc — Pocket framework for MiSTer cores
# Read by apf/apf_constraints.sdc, after the create_clock of clk_74a, clk_74b,
# bridge_spiclk and derive_pll_clocks. The core's own constraints (multicycle
# etc.) stay in its SDC (e.g. Template.sdc), added as SDC_FILE.
#

# Pixel clock to the scaler: pclk/pclk90 registers of pocket_video, in the
# CLK_VIDEO domain. The data always changes at least a quarter of a pixel away
# from their edges (see pocket_video.sv), so the CLK_VIDEO -> pclk transfers
# are safe by construction and are excluded from the analysis (asynchronous groups).
if {[get_collection_size [get_registers -nowarn {ic|u_video|pclk}]] > 0} {
	create_clock -name pocket_vclk -period 50.000 [get_registers {ic|u_video|pclk}]
}
if {[get_collection_size [get_registers -nowarn {ic|u_video|pclk90}]] > 0} {
	create_clock -name pocket_vclk90 -period 50.000 [get_registers {ic|u_video|pclk90}]
}

# Asynchronous groups: Analogue, emu PLL, audio PLL, pixel clock.
# All crossings between these domains go through synchronisers,
# dual-clock FIFOs or quasi-static buses accompanied by a toggle
# (pocket_hps, pocket_bridge, sound_i2s, pocket_video).
set pocket_groups {-group [get_clocks {bridge_spiclk}] -group [get_clocks {clk_74a}] -group [get_clocks {clk_74b}]}
if {[get_collection_size [get_clocks -nowarn {ic|emu|*}]] > 0} {
	append pocket_groups { -group [get_clocks {ic|emu|*}]}
}
if {[get_collection_size [get_clocks -nowarn {ic|u_pll_audio|*}]] > 0} {
	append pocket_groups { -group [get_clocks {ic|u_pll_audio|*}]}
}
if {[get_collection_size [get_clocks -nowarn {pocket_vclk pocket_vclk90}]] > 0} {
	append pocket_groups { -group [get_clocks {pocket_vclk pocket_vclk90}]}
}
eval "set_clock_groups -asynchronous $pocket_groups"

# PSRAM in asynchronous mode: the timing is guaranteed by the pocket_psram
# state machine (sampling at T_ACC cycles, spec + 1 cycle of margin).
set_false_path -to   [get_ports {cram0_* cram1_*}]
set_false_path -from [get_ports {cram0_dq[*] cram1_dq[*] cram0_wait cram1_wait}]
