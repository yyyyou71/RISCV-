"""Synthetic fixtures for report acceptance; never hardware measurements."""
import json,subprocess,sys,tempfile,unittest
from pathlib import Path
PROJECT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(PROJECT/'scripts')); sys.path.insert(0,str(PROJECT/'tests'))
from platform_identity import expected_identity,FIELDS,HEX_FIELDS
from test_coremark_parser import log
@unittest.skipUnless((PROJECT/'reports/pds/burst/build.json').exists(), 'Historical CACHE3-only report fixtures; DUAL1 uses test_dual_log')
class ReportTests(unittest.TestCase):
    def run_report(self,variant='burst',origin='board',mutate=lambda x:x,short=False,validation=True):
        pds=json.loads((PROJECT/'reports/pds'/variant/'build.json').read_text())
        fw=json.loads((PROJECT/'download'/variant/'build.json').read_text())
        hw=expected_identity(pds['prepared']); line=' '.join(f'{key}={hw[key]:08X}' if key in HEX_FIELDS else f'{key}={hw[key]}' for key in FIELDS)
        header='RV32I COREMARK 1.0\nBUILD=CACHE3_BOARD\nBP_ENABLE=1 BP_ENTRIES=32 IMPL_ID=00020501\n'+line+'\n'
        raw=header+log(cycles=249999999 if short else 250000000)+'Compiler flags : '+fw['printed_flags']+'\n'
        if validation: raw+=log('validation')+'Compiler flags : '+fw['printed_flags']+'\n'
        root=PROJECT.parents[1]/'work/cache3_host_fixtures'; root.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=root) as tmp:
            folder=Path(tmp).resolve(); assert folder.is_relative_to(root.resolve())
            path=folder/'SYNTHETIC_NOT_BOARD.txt'; path.write_text(mutate(raw),encoding='utf-8')
            run=subprocess.run([sys.executable,'-X','utf8',str(PROJECT/'scripts/report_board_coremark.py'),str(path),'--origin',origin,'--variant',variant,'--output-dir',str(folder)],capture_output=True,text=True)
            result=json.loads((folder/'result.json').read_text()); report=(folder/'测试结果.md').read_text(encoding='utf-8')
        return run.returncode,result,report,pds
    def test_three_resource_denominators(self):
        for name in ('burst','word','uncached'):
            with self.subTest(name=name):
                code,r,_,pds=self.run_report(variant=name); self.assertEqual(code,0)
                self.assertEqual(r['luts'],pds['audit']['synthesis_luts']); self.assertEqual(r['expected_bitstream_sha256'],pds['bitstream_sha256'])
    def test_simulation_not_accepted(self): self.assertEqual(self.run_report(origin='simulation')[0],2)
    def test_short_not_accepted(self): self.assertEqual(self.run_report(short=True)[0],2)
    def test_missing_validation(self): self.assertEqual(self.run_report(validation=False)[0],2)
    def test_wrong_variant(self):
        code,r,report,_=self.run_report(mutate=lambda s:s.replace('HW_CFG=0000001F','HW_CFG=00000017'))
        self.assertEqual(code,2); self.assertFalse(any(x['eligible_board_measurement'] for x in r['runs'])); self.assertNotIn('CoreMark/MHz',report)
    def test_missing_identity(self): self.assertEqual(self.run_report(mutate=lambda s:'\n'.join(x for x in s.splitlines() if not x.startswith('HW_ID=')))[0],2)
    def test_bad_compile_flags(self): self.assertEqual(self.run_report(mutate=lambda s:s.replace('Compiler flags : ','Compiler flags : BAD '))[0],2)
    def test_wrong_build(self): self.assertEqual(self.run_report(mutate=lambda s:s.replace('CACHE3_BOARD','CACHE2_BURST'))[0],2)
    def test_mixed_log(self): self.assertEqual(self.run_report(mutate=lambda s:s+'RV32I COREMARK 1.0\n'+log('validation'))[0],2)
if __name__=='__main__': unittest.main()
