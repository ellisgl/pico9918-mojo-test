#!/usr/bin/env bash
# Build the Mojo V3 bitstream with Xilinx ISE 14.7.
# Output: build/top.bin (for the Mojo loader) and build/top.bit
set -euo pipefail

ISE=${ISE:-$HOME/Xilinx/14.7/ISE_DS}
PART=xc6slx9-2-tqg144
ROOT=$(cd "$(dirname "$0")" && pwd)
OUT=$ROOT/build

# Generate the ROM before sourcing ISE: its old libstdc++ breaks Pillow.
python3 -I "$ROOT/tools/gen_init_rom.py"

# shellcheck disable=SC1091
set +u; source "$ISE/settings64.sh" >/dev/null; set -u

mkdir -p "$OUT/xst/tmp"
cd "$OUT"

cat > top.prj <<EOF
verilog work "$ROOT/top.v"
verilog work "$ROOT/rtl/tms_bus.v"
verilog work "$ROOT/rtl/debug_uart.v"
EOF

cat > top.xst <<EOF
set -tmpdir xst/tmp
set -xsthdpdir xst
run
-ifn top.prj
-ifmt mixed
-ofn top
-ofmt NGC
-p $PART
-top top
-opt_mode Speed
-opt_level 1
-vlgincdir {"$ROOT/rtl"}
-generics {ROM_FILE="$ROOT/rtl/init_rom.hex" ${EXTRA_GENERICS:-}}
EOF

xst -ifn top.xst -ofn top.syr
ngdbuild -intstyle ise -dd _ngo -uc "$ROOT/mojo-v3.ucf" -p $PART top.ngc top.ngd
map -intstyle ise -p $PART -w -ol high -mt 2 -o top_map.ncd top.ngd top.pcf
par -intstyle ise -w -ol high -mt 4 top_map.ncd top.ncd top.pcf
trce -intstyle ise -v 3 -s 2 -n 3 -fastpaths -xml top.twx top.ncd -o top.twr top.pcf
bitgen -intstyle ise -w -g Binary:yes -g Compress -g UnusedPin:PullNone top.ncd top.bit

grep -E "All constraints were met|Timing errors|constraints not met" top.twr || true
echo "Bitstream: $OUT/top.bin"
