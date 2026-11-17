# Authors and Credits

## rm_BoogieWings_Pocket

**Author**: Umberto Parisi ([rmonic79](https://github.com/rmonic79))

The Boogie Wings / The Great Ragtime Show logic (`rtl/boogwings/`, the project
files in `rtl/common/` and the top level `Template.sv`) and the Analogue Pocket
frame (`core/`, `pocket/`) are copyright Umberto Parisi and distributed under
GNU GPL v3 or later, unless a file header says otherwise.

## Third-party components

This core builds on top of excellent open-source projects. All third-party
sources retain their original copyright and license. The core as a whole
is distributed under **GNU GPL v3 or later** to stay compatible with the
most restrictive upstream (JTFRAME / JTCORES).

| Component | Author | Project | License |
|-----------|--------|---------|---------|
| **FX68K** — M68000 cycle-accurate core | Jorge Cwik | [ijor/fx68k](https://github.com/ijor/fx68k) | GPL-3 |
| **HUC6280** — Hudson HuC6280 (audio CPU) core | Sergey Dvodnenko ([@srg320](https://github.com/srg320)), with Sorgelig and David Shadoff; original design by Gregory Estrade (FPGAPCE) — from the MiSTer TurboGrafx-16 / PC Engine core | [MiSTer-devel/TurboGrafx16_MiSTer](https://github.com/MiSTer-devel/TurboGrafx16_MiSTer) | GPL-3 |
| **JT51** — Yamaha YM2151 (OPM) FM synthesizer | Jose Tejada ([@topapate](https://twitter.com/topapate)) | [jotego/jt51](https://github.com/jotego/jt51) | GPL-3 |
| **JT6295** — OKI MSM6295 ADPCM decoder | Jose Tejada | [jotego/jt6295](https://github.com/jotego/jt6295) | GPL-3 |
| **JTFRAME** — 68000 DTACK clock enable, BCD counter, audio FIR and dual-port RAM, SDRAM64 4-bank SDRAM controller | Jose Tejada | [jotego/jtcores — modules/jtframe](https://github.com/jotego/jtcores/tree/master/modules/jtframe) | GPL-3 |
| **Savestate infrastructure** — ssbus, memory_stream, auto_save_adaptor, ram adaptors | Martin Donlon ([wickerwaka](https://github.com/wickerwaka)) | [wickerwaka/Arcade-TaitoF2_MiSTer](https://github.com/wickerwaka/Arcade-TaitoF2_MiSTer) | GPL-3 |
| **hps_io** (`sys/hps_io.sv`) — the MiSTer core interface the Pocket frame talks to | Till Harbaum, Alexey Melnikov (Sorgelig) | [MiSTer-devel/Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) | GPL-3 |
| **ddram_4port** (`rtl/common/ddram_4port.sv`) — 4-port DDR arbiter | Sorgelig | [MiSTer-devel](https://github.com/MiSTer-devel) | GPL-3 |
| **Analogue Pocket Framework** (`apf/`) | Analogue Enterprises Limited | [open-fpga](https://github.com/open-fpga) | Analogue's license (see the file headers) |
| **MAME** — reference for DECO16IC tilemap, DECO104 protection, DECO ACE, memory maps, timing | MAMEDev team | [mamedev/mame](https://github.com/mamedev/mame) | GPL-2+ |

## Reference

- **Boogie Wings / The Great Ragtime Show arcade hardware** — Data East
  Corporation, 1992 (DE-0297-3 board). This FPGA core is a reimplementation
  from hardware documentation, MAME source code, and observation of real
  hardware behavior. ROMs are **not** included and must be provided by the user.
- **MAME project** — invaluable reference for memory maps, timing, the
  DECO16IC tilemap chips, DECO104 protection, and the DECO ACE mixer.
  [mamedev/mame](https://github.com/mamedev/mame)
