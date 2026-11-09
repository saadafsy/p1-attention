# Open-source (openXC7) place and route for Basys 3

This directory builds the board top `fpga/nexys_a7_top.sv` (MMCM at 100 MHz,
`attn_uart_top` -> `attention_top` with PIPE_ROM=1, PV_SPLIT=0) for the
Basys 3 part xc7a35tcpg236-1 without Vivado:

    yosys synth_xilinx -> nextpnr-himbaechel (xilinx uarch) -> fasm2frames -> xc7frames2bit

Reproduce (WSL, from the repo root):

    bash fpga/openxc7/build.sh

Outputs land in `build/openxc7/` (gitignored): `nexys_a7_top.bit`, `pnr.log`
(timing and utilisation), `report.json`, `synth.log`, `summary.txt`.
Runtime is about 40 minutes, almost all of it in the router.

Nothing here has been run on a board. The bitstream is untested in hardware,
and the timing numbers come from nextpnr's timing model, not from Vivado or a
bench measurement.

## Toolchain

Installed into `~/tools/openxc7` (sourced via `~/tools/openxc7/export.sh`) with
the functions of openXC7/toolchain-installer `toolchain-sources-builder.sh`,
at its pins:

| Component | Source | Revision |
|---|---|---|
| nextpnr (himbaechel, xilinx uarch) | github.com/openXC7/nextpnr | 4e89c503 |
| prjxray (fasm2frames, xc7frames2bit) | github.com/openXC7/prjxray | 54fea88c |
| prjxray-db | github.com/openXC7/prjxray-db | b12466df |
| yosys | ~/oss-cad-suite (0.70+286), not rebuilt | |

Deviations from the stock installer, made because sudo was not used:

- Boost 1.83 (program_options, iostreams, thread and their dependencies)
  came from the Ubuntu 24.04 archive with `apt-get download` + `dpkg -x` into
  `~/tools/openxc7/deps/root`; export.sh adds it to `LD_LIBRARY_PATH`.
  The normal route is `sudo apt-get install libboost-program-options-dev
  libboost-iostreams-dev libboost-thread-dev`.
- FASM's fast ANTLR parser did not build (probably because uuid-dev, an
  installer dependency, is missing here; not investigated further), so fasm2frames uses the pure-Python textX
  parser. It works, it is just slower (about 80 s for this design).
- yosys and fpga-as (the Bazel-built replacement for fasm2frames +
  xc7frames2bit) were not built.
- The xc7a50t chip database is generated once by build.sh (about 1 minute).
  Project X-Ray models xc7a35t as the xc7a50t fabric, so nextpnr's
  "available" counts are the 50t die's. Judge utilisation against the Basys 3
  datasheet limits (20,800 LUTs, 41,600 FFs, 90 DSP48E1, 100 RAMB18).

## Constraints

`fpga/basys3.xdc` is used unchanged. nextpnr reads PACKAGE_PIN, IOSTANDARD
and create_clock. It warns about and ignores `-name`, `set_false_path` (both
async inputs are synchronised in the RTL) and the `[current_design]`
CFGBVS/CONFIG_VOLTAGE properties. The MMCM is supported: nextpnr derives
the 100 MHz `clk` from the 100 MHz input constraint through the
MMCME2_BASE (converted to MMCME2_ADV).

`XILINX_FPGA` is not defined, so the generic `exp_lut_1p` ROM is used.
yosys still maps the four lane exp ROMs to block RAM.
