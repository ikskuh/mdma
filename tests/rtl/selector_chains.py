"""Run the same selector matrix in simulation and in the FPGA sweep."""
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[2]
# The standalone ALU test script shares a name with the gateware package.
sys.path.remove(str(Path(__file__).resolve().parent))
sys.path.insert(0, str(ROOT / 'src/gateware'))
from selector_chain_measure import Chain, cases


def main():
    with TemporaryDirectory(prefix='mdma-selector-chain-') as folder:
        executable = Path(folder) / 'sim'
        for case in cases():
            chain = Chain(case.chain)
            flags = [f'-Pmdma_selector_chain_tb.{key}={value}' for key, value in case.parameters.items()]
            try:
                subprocess.run(['iverilog', '-g2012', '-Wall', '-s', 'mdma_selector_chain_tb',
                                '-o', executable, *flags, *chain.rtl,
                                ROOT / 'tests/rtl/mdma_selector_chain_tb.v'], check=True)
                subprocess.run(['vvp', '-q', executable], check=True)
            except subprocess.CalledProcessError:
                print(f'{case.chain} {case.mode} failed', file=sys.stderr)
                raise
            print(f'{case.chain} {case.mode} passed', flush=True)


if __name__ == '__main__':
    main()
