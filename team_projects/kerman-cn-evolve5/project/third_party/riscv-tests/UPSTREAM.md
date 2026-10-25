Source: https://github.com/riscv-software-src/riscv-tests

Pinned commit: d44511022b356a341a2430cfd65f894b77c35f36

Downloaded on 2026-09-21. The isa/rv32ui, isa/rv64ui directories and
isa/macros/scalar/test_macros.h are preserved as upstream test inputs.
The upstream LICENSE is included. CPU RTL is implemented in this project;
no third-party CPU core is used.

The local tests/env/riscv_test.h replaces the upstream privileged execution
environment only. It ends tests with ECALL and x3 pass/fail status.
No upstream test body has been modified. fence_i (unimplemented Zifencei)
and ma_data (misalignment emulation incompatible with this EEI) are excluded.
Separate directed tests verify FENCE, illegal FENCE.I and misalignment traps.
These are regression tests, not a RISC-V certification claim.

MEXT1 (2026-10-18): isa/rv32um and isa/rv64um were added from the same
pinned checkout. All eight RV32UM entry tests are run using the local EEI
harness; their upstream bodies and RV64 includes are unchanged.
