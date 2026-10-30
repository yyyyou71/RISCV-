# FSPI / video integration merge

Merge local a5be98f with the already pending origin/ziguang_rv32i merge at 428920d.
No fetch, push, vendor IP generation, firmware compilation or board programming performed.

Resolved peripheral_bus.v, soc.v, rv32I.pds and build_firmware.py.
Preserved both FSPI sources and upstream DDR/AI/video sources. PDS top remains acore_dual_top.
Preserved all firmware, C software, IP files and RTL outside peripheral_bus/soc byte-for-byte
against the working tree at the start of conflict resolution (including upstream staged updates).
No CPU pipeline/instruction implementation edits.

Video retains 0x30300. FSPI uses 0x30700 when ENABLE_VIDEO=1 and legacy 0x30300 otherwise.
The bus gates FSPI reads/writes to prevent aliasing; upstream IIC CPU registers remain 0x30400.
Old fspi_service images use the earlier IIC map and are retained unchanged, not certified for
this merge. fspi_link.h still targets standalone FSPI only. See fspi_porting.md before use.
Physical video top does not yet expose FSPI; board_fspi_top is the separate FSPI test entry.

Passed: standalone 2KB FSPI regression, FSPI/video MMIO isolation and 2KB transfer,
IIC FIFO/MMIO regression, actual RV32 IIC test using existing firmware/iic_service images.
Reusable combined test: python3 scripts/check_fspi_integration.py.
PDS reference paths, Python syntax and protected file hashes checked.
Video platform Verilator lint could not run: installed version rejects --timing.
Its diagnostic is build/video-integration/lint/platform_lint.log; historical reports preserved.
No new PDS timing/implementation or hardware validation claimed.
