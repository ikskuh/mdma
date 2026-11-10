#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=${1:-build/rtl}
speed=${2:-8}
case $speed in
    6|7|8) ;;
    *) echo "usage: $0 [output-directory] [6|7|8]" >&2; exit 2 ;;
esac
# Share the configuration checks with the RTL simulation entry points.
rtl_defines=$(PYTHONPATH=src/simulator python3 -c 'from rtl_runner import rtl_defines; print(" ".join(rtl_defines()))')
mkdir -p "$out"
python3 src/rtl/gen_ports.py >"$out/mdma_ports.vh"

pins=(--lpf-allow-unconstrained)
router=()
if [[ -n ${MDMA_ECP5_LPF:-} ]]; then
    pins=(--lpf "$MDMA_ECP5_LPF")
fi
if [[ -n ${MDMA_ECP5_ROUTER:-} ]]; then
    router=(--router "$MDMA_ECP5_ROUTER")
    if [[ $MDMA_ECP5_ROUTER == router2 ]]; then
        router+=(--threads 4 --parallel-refine)
    fi
fi

yosys -Q -T -q -l "$out/ecp5-synth.log" \
    -p "read_verilog $rtl_defines -I$out src/rtl/*.v; synth_ecp5 -top mdma_ecp5 -json $out/ecp5.json"
part="$out/ecp5-$speed"
"${NEXTPNR_ECP5:-nextpnr-ecp5}" --um5g-85k --package CABGA381 --speed "$speed" --freq "${MDMA_ECP5_FREQ:-25}" \
    --json "$out/ecp5.json" "${pins[@]}" "${router[@]}" \
    --textcfg "$part.config" --report "$part-report.json" >"$part-route.log" 2>&1
ecppack --compress "$part.config" "$part.bit"

python3 - "$part-report.json" <<'PYREPORT'
import json
import sys
from pathlib import Path

report = json.loads(Path(sys.argv[1]).read_text())
for clock, data in sorted(report["fmax"].items()):
    print(f"{clock}: {data['achieved']:.2f} MHz")
PYREPORT
