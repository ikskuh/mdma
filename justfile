

python := join( justfile_dir(), ".venv/bin/python")


assemble:
    "{{python}}" src/assembler/mdma_asm.py



setup-venv:
    uv venv --python 3.14
    uv run python -c "import site, pathlib, sys; pathlib.Path(site.getsitepackages()[0], 'local.pth').write_text(sys.argv[1] + '\n')" "$PWD/src/pylibs"
