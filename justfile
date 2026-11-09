

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
    ${CC:-cc} -std=c99 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Wpedantic -Ivendor/qbe src/qbe/mdma.c vendor/qbe/parse.c vendor/qbe/util.c vendor/qbe/cfg.c -o build/qbe-mdma

qbe-test: qbe-build
    "{{python}}" tests/qbe/run.py

qbe-coremark: qbe-build
    "{{python}}" src/qbe/coremark/run.py

qbe-coremark-ecp5: qbe-build
    "{{python}}" src/qbe/coremark/run.py --ecp5
