"""Short P4 unit checks; no model inference, full HDMI stream, or CoreMark."""
from pathlib import Path
import subprocess,json
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/p4';OUT.mkdir(parents=True,exist_ok=True)
gold=subprocess.check_output(['git','show','ff07f43:rtl/requant_q13.v'],cwd=ROOT).decode('utf-8')
(OUT/'requant_gold.v').write_text(gold.replace('module requant_q13 (','module requant_q13_gold ('),encoding='utf-8')
tests={
 'TB_rgb565_box_overlay':['rtl/video/rgb565_box_overlay.v','sim/video/TB_rgb565_box_overlay.v'],
 'TB_video_present_control':['rtl/video/video_present_control.v','sim/video/TB_video_present_control.v'],
 'TB_requant_pipeline':['rtl/scale_mul64x31.v','rtl/requant_q13.v','build/p4/requant_gold.v','sim/ai/TB_requant_pipeline.v']}
results={}
for top,sources in tests.items():
 image=OUT/(top+'.vvp')
 compile_result=subprocess.run(['iverilog','-g2012','-s',top,'-o',str(image),*sources],cwd=ROOT,capture_output=True,text=True,timeout=30)
 output=compile_result.stdout+compile_result.stderr
 if not compile_result.returncode:
  run=subprocess.run(['vvp',str(image)],cwd=ROOT,capture_output=True,text=True,timeout=30)
  output+=run.stdout+run.stderr
  passed=run.returncode==0 and 'PASS' in output
 else:passed=False
 (OUT/(top+'.log')).write_text(output,encoding='utf-8')
 results[top]={'passed':passed,'log':output.strip()}
 print(top,output.strip(),flush=True)
(ROOT/'reports/video_integration/p4_unit_checks.json').write_text(json.dumps(results,indent=2)+'\n',encoding='utf-8')
if not all(r['passed'] for r in results.values()):raise SystemExit(1)
