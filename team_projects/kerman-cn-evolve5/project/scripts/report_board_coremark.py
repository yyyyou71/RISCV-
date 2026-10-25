import argparse,hashlib,json
from pathlib import Path
from parse_coremark import parse_text
from platform_identity import check_runs
PROJECT=Path(__file__).resolve().parents[1]
def main():
    p=argparse.ArgumentParser(); p.add_argument('log',type=Path); p.add_argument('--origin',required=True,choices=('board','simulation'))
    p.add_argument('--variant',choices=('burst','word','uncached'),default='burst'); p.add_argument('--output-dir',type=Path,required=True)
    a=p.parse_args(); a.output_dir.mkdir(parents=True,exist_ok=True)
    impl=json.loads((PROJECT/'reports/pds'/a.variant/'build.json').read_text()); assert impl['status']=='passed'
    fw=json.loads((PROJECT/'download'/a.variant/'build.json').read_text())
    raw=a.log.read_text(encoding='utf-8-sig'); result=parse_text(raw,a.origin,impl['audit']['synthesis_luts'])
    identity=check_runs(raw,impl['prepared'],fw['build_id'],fw['printed_flags'])
    valid=(a.origin=='board' and identity['identity_passed'] and identity['flags_passed'] and len(identity['identity_checks'])==len(identity['flags_checks'])==len(result['runs'])
           and result['both_standard_seed_sets_valid'] and any(x['reportable_coremark'] for x in result['runs']))
    result.update(board_acceptance_passed=valid,variant=a.variant,hardware_identity=identity,
                  expected_bitstream_sha256=impl['bitstream_sha256'],log_sha256=hashlib.sha256(a.log.read_bytes()).hexdigest(),
                  source_note='Origin is supplied by the operator. Hardware configuration is checked per run; UART is not cryptographic bitstream attestation.')
    for row in result['runs']:
        row['reportable_coremark']=valid and row['reportable_coremark']
        row['eligible_board_measurement']=valid and row['eligible_board_measurement']
        if not valid: row.pop('coremark_per_lut',None)
    (a.output_dir/'result.json').write_text(json.dumps(result,indent=2,ensure_ascii=False),encoding='utf-8')
    text=['# CACHE3 上板测试记录','',f'配置：{a.variant}；来源声明：{a.origin}；实物验收：'+('通过' if valid else '未通过，不得作为正式成绩')+'。',
          '',f'预期硬件身份：`{identity["expected_hardware"]}`。',f'逐组身份检查：{identity["identity_checks"]}；编译参数：{identity["flags_checks"]}。','',
          '| 模式 | 次数 | 周期 | 秒 | CRC | ≥10秒 |','|---|---:|---:|---:|---|---|']
    for row in result['runs']: text.append(f'| {row["mode"]} | {row["iterations"]} | {row["cycles"]} | {row["seconds"]} | {row["standard_crc_valid"]} | {row["duration_valid"]} |')
    if valid:
        text+=['','| performance | CoreMark | CoreMark/MHz | CoreMark/LUT |','|---|---:|---:|---:|']
        for index,row in enumerate(result['runs']):
            if row['reportable_coremark']: text.append(f'| {index+1} | {row["iterations_per_second"]} | {row["coremark_per_mhz"]} | {row["coremark_per_lut"]} |')
        text+=['',f'LUT 分母采用本配置完整 SoC 的 PDS 综合值 {impl["audit"]["synthesis_luts"]}，包含硬件观测接口。']
    text+=['','CACHE_STATS 是自复位以来的 32 位累积计数快照，会模 2^32 回绕；不把它当作算法计时区间命中率。',
           '',f'预期位流 SHA-256：`{impl["bitstream_sha256"]}`；实际下载文件仍由操作者确认。']
    (a.output_dir/'测试结果.md').write_text('\n'.join(text)+'\n',encoding='utf-8')
    print('CACHE3_BOARD_REPORT_PASS' if valid else 'CACHE3_REPORT_NOT_VALID'); raise SystemExit(0 if valid else 2)
if __name__=='__main__': main()
