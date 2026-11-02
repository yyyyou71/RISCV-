"""只读检查指定Git分支的部署契约与验证报告，不切换分支、不修改板端工程。"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

from . import PROJECT, OUTPUTS
from .assets import read_y26f


def audit(ref, reference):
    def git(*args):
        return subprocess.check_output(['git', *args], cwd=PROJECT)

    def source(path):
        return git('show', f'{ref}:{path}')

    def report(path):
        return json.loads(source(path))

    commit = git('rev-parse', '--verify', ref + '^{commit}').decode().strip()
    layout = report('reports/integration_review/model_asset.json')
    asset = read_y26f(reference / 'training/export/rearch_int8.bin')
    checks = dict(
        same_reference_weights=layout['binding']['weights_sha256'] == asset['sha256'],
        task_profile=layout['tasks'] == 99 and layout['operators'] == dict(conv2d=72, add=10, concat=14, maxpool5=1, upsample2x=2),
        live_input_bytes=layout['memory_bytes']['input'] == 96 * 96 * 16 * 2,
        three_head_pairs=len(asset['heads']) == 3,
        physical_head_classes=all(asset['convs'][h['cls']]['shape'][0] == 80 for h in asset['heads']),
        board_ai_enabled='parameter integer ENABLE_AI=1' in source('board/acore_dual_top.v').decode(),
        board_firmware_profile='h.task_count!=99' in source('firmware/ai_network.c').decode(),
        pool_ties_even='remainder==120 && q[0]' in source('rtl/video/preprocess/rgb_mean240.v').decode(),
        pool_input_shape='px<1920&&py<1080' in source('rtl/video/preprocess/rgb888_pool96.v').decode(),
    )
    preprocessing = report('reports/preprocess/functional.json')
    timing = report('reports/video_integration/timing_unit_checks.json')
    bindings = {}
    for name, old in {**preprocessing.get('sources', {}), **timing.get('source_snapshot', {})}.items():
        try:
            current = hashlib.sha256(source(name)).hexdigest()
        except subprocess.CalledProcessError:
            current = None
        bindings[name] = dict(recorded_sha256=old, current_sha256=current, matches=current == old)
    # 保留报告自身的验证范围，不能把短算子检查当成此分支的整网数值证明。
    return dict(schema=1, ref=ref, commit=commit, static_profile_passed=all(checks.values()), checks=checks,
        asset_sha256=asset['sha256'], physical_classes=80, active_training_classes={'0': 'face'},
        input_shape=[96, 96, 3], tasks=99, operators=layout['operators'],
        original_asset_is_face_detector=False,
        report_source_bindings=bindings,
        existing_report_scope=dict(preprocess_passed=preprocessing['passed'],
            targeted_rtl_passed=timing['passed'], full_network_at_board_head=timing['full_network_run'],
            board_verified_by_this_audit=False),
        limitations=['本检查未读取板上实际DDR镜像或位流，不能认证实板识别精度',
                     '已上板分支的计算流水线有修改，原main分支整网PASS不自动覆盖这些修改',
                     '报告哈希不匹配项需要结合最新对应测试判断，不应沿用旧通过结论',
                     '现有整数权重对应色块任务，必须重新训练并验收人脸精度'])


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--ref', default='origin/ziguang_rv32i')
    p.add_argument('--reference', type=Path, default=PROJECT.parent / 'materials/TridentVision')
    p.add_argument('--out', type=Path, default=OUTPUTS / 'board_audit.json')
    args = p.parse_args()
    result = audit(args.ref, args.reference)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'report_source_bindings'}, ensure_ascii=False, indent=2))
    print('完整报告：', args.out)
    if not result['static_profile_passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
