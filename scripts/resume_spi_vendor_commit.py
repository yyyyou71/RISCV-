"""Resume the unchanged official DDR/CPU/SPI simulation from latest.ckp.

Uses its existing compiled work library. Do not rebuild or modify that library
before restoration. The simulation still covers only tail CHUNK/COMMIT.
"""
from pathlib import Path
import datetime,json,os,re,shutil,subprocess,winreg

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/spi-vendor-commit'
checkpoint=OUT/'latest.ckp'
assert checkpoint.is_file() and (OUT/'work').is_dir()
stamp=datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
saved=OUT/f'resume_start_{stamp}.ckp'
shutil.copyfile(checkpoint,saved)
script=OUT/f'resume_{stamp}.do'
script.write_text('''onerror {quit -code 1 -f}
puts "VENDOR_CPU_RESUMED"
for {set step 0} {$step < 51} {incr step} {
 run 100 us
 puts "VENDOR CPU checkpoint boundary"
 if {[catch {checkpoint latest.pending} reason]} {puts "CHECKPOINT failed: $reason"} else {file rename -force latest.pending latest.ckp}
}
quit -f
''')
report_path=ROOT/'reports/spi_image/vendor_cpu_spi_commit.json'
report=json.loads(report_path.read_text())
previous=dict(report)
previous['state']='interrupted';previous['interruption_confirmed']=datetime.datetime.now().isoformat()
(OUT/f'interrupted_report_{stamp}.json').write_text(json.dumps(previous,indent=2)+'\n')
logfile=OUT/f'resume_{stamp}.log'
report.update(state='running',passed=False,resumed=datetime.datetime.now().isoformat(),
              resume_checkpoint=saved.relative_to(ROOT).as_posix(),log=logfile.relative_to(ROOT).as_posix(),
              previous_log=previous['log'])
report.pop('finished',None);report.pop('exit_code',None)
report_path.write_text(json.dumps(report,indent=2)+'\n')
env=os.environ.copy()
with winreg.OpenKey(winreg.HKEY_CURRENT_USER,'Environment') as key:
    for name in ['LM_LICENSE_FILE','MGLS_LICENSE_FILE']:
        try:env[name]=winreg.QueryValueEx(key,name)[0]
        except FileNotFoundError:pass
with logfile.open('w') as log:
    process=subprocess.Popen(['C:/diskE/modelsim/win64/vsim.exe','-c','-restore',saved.name,
        '-wlf',f'resume_{stamp}.wlf','-l',f'resume_{stamp}.transcript','-do',script.name],
        cwd=OUT,env=env,stdout=log,stderr=subprocess.STDOUT)
    try:rc=process.wait(timeout=10800)
    except subprocess.TimeoutExpired:
        subprocess.run(['taskkill','/PID',str(process.pid),'/T','/F'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        rc=process.wait();report['state']='timeout'
text=logfile.read_text(errors='replace')
restored=re.search(r'Restoring state at time ([^,\r\n]+)',text)
passed=rc==0 and 'PASS vendor CPU SPI CHUNK/COMMIT:' in text
report.update(passed=passed,exit_code=rc,finished=datetime.datetime.now().isoformat(),
              restored_at=restored.group(1) if restored else None)
if report['state']!='timeout':report['state']='passed' if passed else 'failed'
report_path.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
if not passed:raise SystemExit(1)
