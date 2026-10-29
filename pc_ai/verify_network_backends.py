#!/usr/bin/env python3
"""用真实短区间核对两种仿真后端，并检查错误数据与漏装载不能误报通过。"""
import sys
sys.dont_write_bytecode=True
import argparse
import json
from pathlib import Path
import resource
import subprocess
from prepare_trident_network import ROOT,dump,checked


def no_core_dump():resource.setrlimit(resource.RLIMIT_CORE,(0,0))


def negative_checks(directory):
    """只改本次测试的仿真输入，退出时恢复；不改原始C黄金文件。"""
    initial_path=directory/'initial.mem';golden_path=directory/'golden.mem'
    initial=initial_path.read_text();golden=golden_path.read_text()
    rows=initial.splitlines();wanted=golden.splitlines()
    output=int((directory/'outputs.mem').read_text().splitlines()[0],16)>>32
    infos={s:json.loads((directory/f'fixtures_{s}.json').read_text()) for s in ('iverilog','verilator')}
    # 从预装载的模型头和任务记录取得真实输入A地址。
    records={int(row,16)>>128:int(row,16)&((1<<128)-1) for row in rows}
    table=(records[0x10010]>>32)&0xffffffff
    input_a=(records[table]>>32)&0xffffffff
    missing=[row for row in rows if int(row,16)>>128!=input_a]
    checked(len(missing)==len(rows)-1,'测试没有找到输入A的第一个DDR字')
    broken=wanted.copy()
    index=next(i for i,row in enumerate(broken) if int(row,16)>>256==output)
    broken[index]=f'{int(broken[index],16)^1:072x}'
    results={}
    try:
        for case in ('expected_data','missing_input'):
            initial_path.write_text(initial if case=='expected_data' else '\n'.join(missing)+'\n')
            golden_path.write_text('\n'.join(broken)+'\n' if case=='expected_data' else golden)
            for simulator,info in infos.items():
                command=['vvp','test.vvp'] if simulator=='iverilog' else [str(Path(info['compile_log']).parent/'obj/network_sim')]
                command.extend([f'+TASK_INITIAL={len(rows) if case=="expected_data" else len(missing)}',
                    f'+TASK_GOLDEN={info["golden"]}',f'+NETWORK_TASKS={info["count"]}',f'+NETWORK_START={info["start"]}'])
                r=subprocess.run(command,cwd=directory,capture_output=True,text=True,timeout=30,preexec_fn=no_core_dump)
                log=r.stdout+r.stderr;(directory/f'negative_{case}_{simulator}.log').write_text(log)
                marker='network mismatch' if case=='expected_data' else 'DDR3: read of uninitialized word'
                checked(r.returncode!=0 and marker in log,simulator+'没有正确拒绝'+case)
                results[case+'_'+simulator]=True
    finally:
        initial_path.write_text(initial);golden_path.write_text(golden)
    return results


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,default=ROOT/'pc_ai/outputs/trident_network_smoke')
    parser.add_argument('--check-existing',action='store_true',help='已有两后端及缓存复用报告时，只核对并运行负向检查')
    args=parser.parse_args();out=args.out.resolve()
    if not args.check_existing:
        for simulator,segment,extra in (('verilator','5:1',['--golden-limit','9']),('iverilog','5:1',[]),('verilator','7:2',[])):
            subprocess.run([sys.executable,str(ROOT/'pc_ai/prepare_trident_network.py'),'--out',str(out),'--size','32',
                '--segment',segment,'--simulator',simulator,'--run',*extra],check=True)
    directory=out/'segments/005_001'
    reports={s:json.loads((directory/f'result_{s}.json').read_text()) for s in ('iverilog','verilator')}
    for report in reports.values():checked(report['passed'],'短区间未通过')
    fields=('start','count','binding','firmware_sha256','cycles','issues','checked_words')
    for field in fields:checked(reports['iverilog'][field]==reports['verilator'][field],'后端结果不一致：'+field)
    reuse=json.loads((out/'segments/007_002/result_verilator.json').read_text())
    checked(reuse['passed'] and reuse['model_reused'] and reuse['model_key']==reports['verilator']['model_key'],'跨区间没有复用编译模型')
    negative=negative_checks(directory)
    dump(out/'backend_comparison.json',dict(passed=True,cycles=reports['verilator']['cycles'],
        checked_words=reports['verilator']['checked_words'],negative_checks=negative,model_reused=True,
        simulation_wall_seconds={s:r['simulation_wall_seconds'] for s,r in reports.items()},
        note='这里只测32x32残差ADD区间，耗时不含编译，不作为整网加速倍数'))
    print('PASS network_backends: outputs/cycles match, cache reused, four negative checks rejected')


if __name__=='__main__':main()
