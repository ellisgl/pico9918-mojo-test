# Mojo V3 → PICO9918 (Waveshare RP2040-PiZero) bus test

The Mojo V3 (Spartan-6 XC6SLX9) acts as the host CPU for the PICO9918 firmware in
`~/Projects/Electronics/Digital/waveshare-PiZero-pico9918`. It drives the TMS9918A
CPU bus (CD0–7, MODE, /CSR, /CSW, RESET), services /INT, and draws a test screen
over the PiZero's mini-HDMI output.

## Wiring

Both sides are **3.3 V**, so wire them directly with no level shifters. Power the
PiZero from its own USB-C and connect **GND** between the boards. **Do not** connect
the PiZero header's 5 V pins (2, 4).

| Signal | TMS9918A pin | Mojo pin | PiZero header pin | RP2040 GPIO |
|---|---|---|---|---|
| CD0 (MSB) | 17 | P10 | 29 | GPIO15 |
| CD1 | 18 | P9  | 7  | GPIO14 |
| CD2 | 19 | P8  | 33 | GPIO13 |
| CD3 | 20 | P7  | 21 | GPIO12 |
| CD4 | 21 | P6  | 19 | GPIO11 |
| CD5 | 22 | P5  | 23 | GPIO10 |
| CD6 | 23 | P2  | 32 | GPIO9  |
| CD7 (LSB) | 24 | P1  | 24 | GPIO8  |
| MODE | 13 | P11 | 11 | GPIO17 |
| /CSR | 15 | P12 | 12 | GPIO18 |
| /CSW | 14 | P14 | 35 | GPIO19 |
| /INT (VDP → FPGA) | 16 | P15 | 38 | GPIO20 |
| RESET (active low) | 34 | P16 | 40 | GPIO21 |
| GROMCLK (VDP → FPGA) | 37 | P17 | 8  | GPIO4 |
| CPUCLK (VDP → FPGA) | 38 | P21 | 10 | GPIO5 |
| GND | 12 | any GND | 6, 9, 14, 20, 25, 30, 34, 39 | – |

- TMS9918A naming has **CD0 as the most significant bit**. The RTL declares the port
  as `[0:7] CD`, so `CD<0>` in the UCF is the MSB.
- Leave PiZero header pins 3, 5, 13, 15, 16, 18, 22, 36 and 37 unconnected (HDMI
  TMDS/DDC/CEC). Pin 26 (MODE1) is unused.
- Optional: 100 Ω series resistors on CD0–7 limit current if both sides ever drive the
  bus at the same time (for example while either board is configuring).
- Don't insert a TF card in the PiZero: GPIO18–21 are shared with the card slot.

## What it does

1. Holds RESET low for 10 ms, then waits 250 ms.
2. Runs the init script (`rtl/init_rom.hex`): registers, clears 16 KB of VRAM, loads the
   PICO9918 firmware's font, colour bars, a 16×16 sprite and the text.
3. **VRAM readback test:** writes 256 bytes to 0x3000, reads them back and compares. This
   exercises /CSR and bus turnaround.
4. **Frame loop:** on each /INT, reads the status register (which acknowledges the
   interrupt), then writes the frame counter, status byte, test result, resync count and
   the sprite's new position.
5. **Watchdog:** if no frame arrives for 500 ms (PiZero unplugged, rebooted or powered
   late), or the readback test fails (the VDP wasn't ready, so the init was lost too), the
   FPGA goes back to step 1 and adds one to `RESYNCS`.
6. **Status polling:** while waiting for /INT, the status register is read every 1 ms. If
   its frame flag is set, the frame runs anyway. The `INT PIN` and `POLLED` counters on
   screen show which path each frame came through. With everything working, `POLLED`
   stays at 0.

The expected screen (from simulation; the sprite isn't shown):

```
   MOJO V3 -> PICO9918 TEST

  FRAME     $0008        counts up at 60 Hz
  STATUS    $9F          INT flag set, 5th-sprite number 31
  READBACK  PASS $00     PASS + mismatch count
  RESYNCS   $00          watchdog re-inits
  INT PIN   $08  POLLED $00   frames per source (low byte)

 ##############################   15 colour bars

  SPRITE + BARS = WRITES OK
```

The PICO9918 splash overlay also shows in the bottom border for the first 600 frames (about 10 s).

### Mojo LEDs

| LED | Meaning |
|---|---|
| 0 | Heartbeat (frame counter bit 5, about 1 Hz) |
| 1 | Init script done |
| 2 | Readback PASS |
| 3 | Readback FAIL |
| 4 | /INT seen recently |
| 5 | GROMCLK toggling |
| 6 | CPUCLK toggling |
| 7 | Waiting for the VDP (reset, boot, or no /INT for 50 ms or more) |

Healthy: 0 blinking, 1, 2, 4, 5, 6 on; 3 and 7 off.

## Serial debug report

Four times a second the FPGA sends a line over the Mojo's USB serial port (`/dev/ttyACM0`;
open it at any baud rate):

```
S=0D I=1 ST=80 FR=248F IP=26 PL=00 RS=00 ER=00 T=P B=00 D=00 ID=00
```

| Field | Meaning |
|---|---|
| `S` | Main FSM state (`0D` = waiting for a frame) |
| `I` | /INT pin level (1 = idle) |
| `ST` | Last status register read |
| `FR` | Frame counter |
| `IP` / `PL` | Frames started by the /INT pin / found by polling (low byte) |
| `RS` | Re-inits (watchdog or failed readback) |
| `ER` / `T` | Readback mismatches / result (`P`, `F`, `-`) |
| `B` / `D` / `ID` | F18A SR4 / SR5 / SR1, only with `DIAG_ENABLE=1` (see below) |

```bash
python3 -c "import serial; p=serial.Serial('/dev/ttyACM0'); [print(p.readline().decode().strip()) for _ in range(8)]"
```

### Firmware boot trace (`DIAG_ENABLE`)

With `DIAG_ENABLE=1` the FPGA unlocks F18A mode every 100 ms and reads SR1 (ID, `E8`),
SR4 and SR5. With the PICO9918 firmware built with `-DPICO9918_BOOT_TRACE=ON`, SR4 is the
core 0 start-up stage (`23` = reached the main loop, bit 7 = hard fault) and SR5 the DVI
line-interrupt count (it should change between reports). It's off by default because it
puts the VDP in F18A mode, which a plain TMS9918A test doesn't need. With it on, /INT ran
for 3,600+ frames with no dropouts.

```bash
EXTRA_GENERICS='DIAG_ENABLE=1' ./build.sh
```

## Bus timing (50 MHz, `rtl/tms_bus.v`)

| Phase | Cycles | Time |
|---|---|---|
| MODE/CD setup before strobe | 3 | 60 ns |
| /CSW low | 15 | 300 ns |
| /CSR low (CD sampled at the end) | 20 | 400 ns |
| Hold after strobe | 3 | 60 ns |
| Gap between accesses (`T_GAP`) | 100 | 2 µs |

These timings follow the PICO9918 PIO programs: both strobes are debounced for about
32 ns, read data appears about 60 ns after /CSR falls, and every access interrupts the
RP2040, which needs time to update its read-ahead before the next access. If the readback
test fails, increase `T_GAP` in `top.v`.

## Build, simulate, load

```bash
./build.sh                    # ISE 14.7 -> build/top.bin (also regenerates the ROM)

cd sim                        # behavioural PICO9918 model + timing checks
iverilog -g2005 -I ../rtl -o tb.vvp tb_top.v vdp_model.v ../top.v ../rtl/tms_bus.v
vvp -n tb.vvp                 # prints the screen, ends with *** TEST PASSED ***
```

Load it with `s6-load` from `~/Projects/FPGA/spartan6-toolchain`:

```bash
~/Projects/FPGA/spartan6-toolchain/build/target/release/s6-load --flash build/top.bin  # flash, verified
~/Projects/FPGA/spartan6-toolchain/build/target/release/s6-load build/top.bin          # RAM only
```

To change the text, colours or VRAM layout, edit `tools/gen_init_rom.py`. It also writes
`rtl/layout.vh`, so the addresses the RTL updates each frame follow the layout.

## Files

| Path | Contents |
|---|---|
| `top.v` | Sequencer: reset, init ROM, readback test, frame loop, watchdog, LEDs |
| `rtl/tms_bus.v` | TMS9918A bus master (one read or write per request) |
| `rtl/debug_uart.v` | Serial debug report through the Mojo's AVR (500 kbaud) |
| `rtl/init_rom.hex`, `rtl/layout.vh` | Generated init script and VRAM addresses |
| `tools/gen_init_rom.py`, `tools/font.png` | ROM generator; font copied from PICO9918 (MIT, see `tools/font.png.LICENSE`) |
| `sim/vdp_model.v`, `sim/tb_top.v` | Bus model with protocol checks, testbench |
| `mojo-v3.ucf` | Pin constraints |

## License

BSD 3-Clause, see [`LICENSE`](LICENSE). The exception is `tools/font.png`, which comes from
[PICO9918](https://github.com/visrealm/pico9918) under the MIT License
(see [`tools/font.png.LICENSE`](tools/font.png.LICENSE)).
