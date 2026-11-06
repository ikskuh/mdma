

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
