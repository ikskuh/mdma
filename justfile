

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
    "{{python}}" tests/rtl/run.py

fpga-build:
    src/rtl/build.sh

rtl-benchmark:
    "{{python}}" tests/rtl/run.py --benchmark

qbe-build:
    mkdir -p build
    awk '$1 && $1 !~ /^#/ {printf "\"%s %s %s\\n\"\n", $1, $2, $3}' src/qbe/profiles/ecp5.conf > build/mdma_default_profile.h
    ${CC:-cc} -std=c99 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Wpedantic -Ivendor/qbe -Ibuild src/qbe/mdma.c src/qbe/schedule.c vendor/qbe/parse.c vendor/qbe/util.c vendor/qbe/cfg.c vendor/qbe/ssa.c vendor/qbe/live.c vendor/qbe/mem.c vendor/qbe/alias.c vendor/qbe/load.c vendor/qbe/fold.c -o build/qbe-mdma

qbe-test: qbe-build
    "{{python}}" tests/qbe/run.py

qbe-coremark *args: qbe-build
    "{{python}}" src/qbe/coremark/run.py {{args}}

qbe-coremark-ecp5 *args: qbe-build
    "{{python}}" src/qbe/coremark/run.py --ecp5 {{args}}

report-status: qbe-build
    "{{python}}" src/qbe/report_status.py
