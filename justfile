

python := join( justfile_dir(), ".venv/bin/python")


assemble:
    "{{python}}" src/assembler/mdma_asm.py


test:
    #!/usr/bin/env bash
    set -eu
    "{{python}}" -m unittest discover -s tests -v
    output_dir=$(mktemp -d)
    trap 'rm -rf "$output_dir"' EXIT
    for source in examples/*.mdma; do
        "{{python}}" src/assembler/mdma_asm.py "$source" -o "$output_dir/$(basename "$source" .mdma).bin"
    done


setup-venv:
    uv venv --python 3.14
    uv run python -c "import site, pathlib, sys; pathlib.Path(site.getsitepackages()[0], 'local.pth').write_text(sys.argv[1] + '\n')" "$PWD/src/pylibs"

rtl-test:
    #!/usr/bin/env bash
    set -euo pipefail
    output_dir=$(mktemp -d)
    trap 'rm -rf "$output_dir"' EXIT
    for ports in 1 2; do
        iverilog -g2012 -DMDMA_BRAM_PORTS="$ports" -s mdma_bram_tb -o "$output_dir/bram" \
            src/benchmarks/compare/mdma_bram.v tests/rtl/mdma_bram_tb.v
        vvp "$output_dir/bram"
    done
    "{{python}}" tests/rtl/alu.py
    for implementation in 0 1 2; do
        for shape in 64x4 64x5 64x8 64x16 64x32 64x64 128x8 1x8; do
            iverilog -g2012 -Wall -s mdma_fifo_tb -o "$output_dir/fifo" \
                -Pmdma_fifo_tb.IMPLEMENTATION="$implementation" \
                -Pmdma_fifo_tb.WIDTH="${shape%x*}" -Pmdma_fifo_tb.DEPTH="${shape#*x}" \
                src/gateware/mdma_fifo.v tests/rtl/mdma_fifo_tb.v
            vvp "$output_dir/fifo"
        done
    done
    iverilog -g2012 -Wall -s mdma_fifo_fu_tb -o "$output_dir/fifo-fu" \
        src/gateware/mdma_fifo.v src/gateware/alu/mdma_arith.v \
        src/gateware/alu/mdma_alu_result.v tests/rtl/mdma_fifo_tb.v
    vvp "$output_dir/fifo-fu"

alu-measure *args:
    "{{python}}" src/gateware/alu/measure.py {{args}}

fifo-measure *args:
    "{{python}}" src/gateware/fifo_measure.py {{args}}

qbe-build:
    mkdir -p build
    awk '$1 && $1 !~ /^#/ {printf "\"%s %s %s\\n\"\n", $1, $2, $3}' src/qbe/profiles/ecp5.conf > build/mdma_default_profile.h
    ${CC:-cc} -std=c99 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Wpedantic -Ivendor/qbe -Ibuild src/qbe/mdma.c src/qbe/schedule.c vendor/qbe/parse.c vendor/qbe/util.c vendor/qbe/cfg.c vendor/qbe/ssa.c vendor/qbe/live.c vendor/qbe/mem.c vendor/qbe/alias.c vendor/qbe/load.c vendor/qbe/fold.c -o build/qbe-mdma

qbe-test: qbe-build
    "{{python}}" tests/qbe/run.py

qbe-aligned-cproc source:
    #!/usr/bin/env bash
    set -euo pipefail
    output="$PWD/build/cproc-alignment"
    mkdir -p "$output"
    git -C "{{source}}" archive d1c53ddf56571573a7025324c8dd5c6d547a4d1f | tar -x -C "$output"
    patch -d "$output" -p1 < src/qbe/cproc-alignment.patch
    cd "$output"
    ./configure
    make -j4

qbe-examples *names: qbe-build
    "{{python}}" examples/qbe/run.py {{names}}

qbe-coremark *args: qbe-build
    "{{python}}" src/qbe/coremark/run.py {{args}}

report-status: qbe-build
    "{{python}}" src/qbe/report_status.py

vexriscv-rtl:
    cd vendor/vexriscv && ${SBT:-sbt} 'runMain vexriscv.demo.GenFullNoMmuNoCacheSimpleMul'
    mkdir -p build/compare
    cp vendor/vexriscv/VexRiscv.v build/compare/VexRiscv.v

compare-fpga *args:
    "{{python}}" src/benchmarks/compare/run.py {{args}}
