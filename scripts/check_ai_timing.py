"""WSL short checks for AI timing edits; no CoreMark or full model inference."""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--stage', default='final')
    parser.add_argument('--operators', type=int, nargs='+', default=[2,3,4,5,6])
    args = parser.parse_args()
    out = ROOT / 'build/timing-closure' / args.stage
    out.mkdir(parents=True, exist_ok=True)
    reference = args.reference.resolve()
    records = []

    def run(command, cwd, name):
        result = subprocess.run(list(map(str, command)), cwd=cwd, capture_output=True,
                                text=True, timeout=120)
        text = result.stdout + result.stderr
        (out / (name + '.log')).write_text(text)
        if result.returncode:
            raise RuntimeError(name + ': ' + text[-2000:])
        return text

    for mode, source, counts_name in [
        (2, 'w8a16_ddr_vectors.c', 'counts.json'),
        (3, 'export_add_tasks.c', 'add_counts.json'),
        (4, 'export_concat_tasks.c', 'concat_counts.json'),
        (5, 'export_maxpool_tasks.c', 'maxpool_counts.json'),
        (6, 'export_upsample_tasks.c', 'upsample_counts.json'),
    ]:
        if mode not in args.operators:
            continue
        case = out / str(mode)
        (case / 'ddr').mkdir(parents=True, exist_ok=True)
        run(['gcc', '-O2', '-std=c11', '-DTRIDENT_SOURCE=' + json.dumps(str(reference / 'training/export/rearch_fixed.c')),
             '-I', reference / 'c_model', ROOT / 'pc_ai' / source, '-lm', '-o', case / 'export'], case, f'export_compile_{mode}')
        run([case / 'export', reference / 'training/export/rearch_int8.bin', *(['engine'] if mode == 2 else [])],
            case, f'export_{mode}')
        vectors = case if mode == 2 else case / 'ddr'
        counts = json.loads((case / counts_name).read_text())
        initial_count=counts.get('initial',counts.get('initial_words'))
        golden_count=counts.get('golden',counts.get('golden_words'))
        binary = case / 'engine.vvp'
        run(['iverilog', '-g2012', '-s', 'TB_conv2d_ddr_engine', '-y', ROOT / 'sim/models', '-y', ROOT / 'rtl',
             '-DDDR3_MODEL_SLOTS=32768', '-DDDR3_MODEL_STRICT_READS',
             f'-PTB_conv2d_ddr_engine.QUANT_TEST={mode}', '-PTB_conv2d_ddr_engine.MAX_LAYERS=2',
             '-o', binary, ROOT / 'sim/ai/TB_conv2d_ddr_engine.v', ROOT / 'sim/ddr3/ddr3.sv'], case, f'compile_{mode}')
        text = run(['vvp', binary, f'+JOBS={counts["layers"]}', f'+INITIAL={initial_count}',
                    f'+GOLDEN={golden_count}', '+ddr3_random_stalls=1'], vectors, f'run_{mode}')
        summary = next((line for line in text.splitlines() if line.startswith('PASS ')), None)
        if not summary:
            raise RuntimeError(f'missing PASS for operator {mode}')
        records.append(dict(mode=mode, passed=True, initial_layers_checked=min(2,counts['layers']),
                            fixture_layers=counts['layers'], summary=summary))
        print(f'operator {mode}: {summary}', flush=True)
    destination = ROOT / 'reports/video_integration' / ('timing_' + args.stage + '_checks.json')
    destination.write_text(json.dumps(dict(passed=True, scope='two small layers/operator, C golden, invalid configs, backpressure/reset/fault',
                                          full_network_run=False, cases=records), indent=2) + '\n')


if __name__ == '__main__':
    main()
