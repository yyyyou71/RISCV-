# RK I2C adaptation scaffold

Update: CPU FIFO/MMIO integration is now available. See rk_cpu_link.md for the
current deployment procedure and register map. IIC_BOOT_TEST now defaults to 0.
2026-10-29: board pins are SCL=P19/SDA=R19, LVCMOS33. CPU MMIO moved to
0x30400; the wire address remains 0x66. The root project uses acore_dual_top.
The pending items below describe the earlier scaffold; current integration
status is recorded in ai_board_integration_plan.md and rk_cpu_link.md.
The bring-up description below applies only with IIC_BOOT_TEST=1.


The adapter in rtl/rk_iic is now instantiated as u_rk_iic in
board/board_top.v. It shares the existing 25 MHz clock and board reset, and
exposes iic_scl/iic_sda at the board top. The four RTL files are listed in
rv32I.pds and scripts/implement.tcl. No additional PLL or vendor IP is needed.
CPU MMIO is connected through a 64-byte transmit FIFO; UART RX is not needed for CPU-produced data.

## Integrated bring-up behavior

For the optional bring-up mode, set IIC_BOOT_TEST to 1. Each board reset queues one byte, 0xA5, for RK
to read. Reading register 0x21 does not consume it; writing 1 to 0x22 clears
it. The test source sends no more bytes until the next board reset. Set
IIC_BOOT_TEST=0 when connecting the application producer.
RK parameter commits drive rk_param_data and a one-clock rk_param_update
pulse inside board_top. These signals feed CPU MMIO. The iic_service firmware applies parameters to GPIO
and echoes them; the original selftest firmware does not consume parameters.

Run python3 scripts/check_sim.py --test TB_board_iic from the project root
in WSL to test the actual board wrapper. It covers the boot byte, repeated
reads, consume-once behavior, scratch readback, parameter commit and reset
recovery. TB_rk_iic tests the standalone adapter.

After confirming physical constraints, rebuilding and loading the FPGA, run
the following on RK with the actual bus device (i2c-0 is only an example):

    ./rk_iic_demo /dev/i2c-0 status
    ./rk_iic_demo /dev/i2c-0 recv
    ./rk_iic_demo /dev/i2c-0 recv
    ./rk_iic_demo /dev/i2c-0 set 0x12345678

Expect version 1 and a pending byte initially; the first recv yields 0xA5,
the second reports empty. After FPGA reset, recv yields 0xA5 again. Parameter
commit is checked by register readback/sequence; no LED is assigned to it.

## Structure and provenance

- `rk_iic_adapter.v`: application-facing top, default 25 MHz and 7-bit address 0x66.
- `rk_iic_frontend.v`: synchronization/filtering and open-drain SDA; adapted from
  `iic_slave_test/src/i2cSlave.v`, externalizing the register interface.
- `rk_iic_serial.v`: adapted from the example's `serialInterface.v`.
- `rk_iic_regs.v`: new parameter bank and single-byte FPGA-to-RK mailbox.

The two adapted protocol files retain Steve Fielding/OpenCores copyright and
LGPL notices. Changes: namespaced modules, local constants replacing global
macros, configurable address/filter lengths, initialized register pointer.

## Application interface

All ports must be synchronous to `clk`. No clock-domain bridge is included.
Set `CLK_FREQ_MHZ` to the actual integer MHz input clock (initial target: 25).
Bring reset high only after the input clock is stable. A board PLL may be reused;
this scaffold does not require a new vendor IP. Start with RK SCL at 100 kHz.
Higher rates and other clock configurations require separate validation.

`param_update` pulses one cycle when `param_data` receives a complete committed
32-bit parameter. This means accepted by the bank, not applied at a video frame
boundary. Such application acknowledgment is a later integration step.

`uplink_valid && uplink_ready` at a rising edge accepts one byte. Producer must
hold data/valid until accepted. This is a one-byte mailbox, not a UART RX or FIFO.
A UART receiver cannot generally be stalled; put a sized FIFO before this port
and define overflow handling before connecting a live byte stream.

## Proposed register map

I2C uses 7-bit address 0x66; wire address bytes are 0xCC (write), 0xCD (read).
Write format: START, address+W, register index, byte(s), STOP.
Read format: write index, repeated START, address+R, data, final NACK, STOP.
Indices auto-increment.

| Index | Access | Function |
|---|---|---|
| 00 | RW | Scratch echo register |
| 01 | RW | Reserved control byte; readback only, no LED connection |
| 02 | RO | bit0: uplink byte available |
| 03 | RO | Interface version = 1 |
| 10..13 | RW | 32-bit parameter shadow, least-significant byte first |
| 14 | WO | Write 1 to commit shadow; reads return 0 |
| 15 | RO | Commit sequence, wraps at 256 |
| 20 | RO | Uplink byte count: 0 or 1 |
| 21 | RO | Uplink byte; non-destructive read; empty returns 0 |
| 22 | WO | Write 1 after consuming byte to release mailbox |

Other indices return 0 and ignore writes. RO writes are ignored. Use one host
consumer; acknowledge each successfully read byte once. Duplicate acknowledgments
after a new byte arrives can discard that new byte; reliable retry/sequence
handling is future work, not a guaranteed message protocol in this scaffold.

## Local smoke test (WSL, project root)

```sh
mkdir -p obj_iv
iverilog -g2012 -s TB_rk_iic -o obj_iv/TB_rk_iic.out sim/TB_rk_iic.v rtl/rk_iic/*.v
vvp obj_iv/TB_rk_iic.out
```

## Pending physical and application integration

1. Verify actual PG2L100H device/package, clock, I2C nets and bank supply against
   the target schematic. Example pins P19/R19 and LVCMOS33 are references only.
2. SDA must use open-drain behavior with appropriate pull-up voltage. Do not
   copy the example's LED voltage constraints into this project.
3. Add verified SCL/SDA pin, voltage and timing constraints; connect application
   parameter/UART FIFO interfaces or a CPU MMIO adapter as required.
4. Confirm RK pinmux, I2C controller number, driver ownership and bus speed.
5. Perform board readback, reset recovery, burst/overflow and coexistence tests.

No board constraints, PLL IP, RK driver changes, live-board access or flashing
are performed by this scaffold. RTL smoke simulation is not electrical or
timing-closure validation.
