"""Synthetic duration fixtures test rejection logic, never board performance."""
import json,re,sys,unittest
from pathlib import Path
P=Path(__file__).resolve().parents[1];sys.path.insert(0,str(P/'scripts'))
from verify_dual_log import verify

@unittest.skipUnless((P/'reports/final_coremark/dual/simulation.json').exists(), 'Historical DUAL1 fixtures; current release uses test_evolve_log')
class DualLogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixtures={}
        for config in ('scalar','wide_single','dual'):
            root=P/'reports/final_coremark'/config
            prepared=json.loads((root/'simulation.json').read_text())['prepared']
            text=(root/'coremark_uart.txt').read_text();prefix=text[:text.index('CM_BEGIN ')]
            runs=re.findall(r'(CM_BEGIN .*?CM_READY)',text,re.S)
            short=prefix+runs[2]+'\n'+runs[3]+'\n'
            good=re.sub(r'(?<!\w)iterations=8\b','iterations=2048',short).replace('requested_iterations=8','requested_iterations=2048')
            good=re.sub(r'(?m)^(CM_RESULT .*?cycles=)\d+',r'\g<1>300000000',good).replace('time_ok=0 score_valid=0','time_ok=1 score_valid=1')
            cls.fixtures[config]=(prepared,short,good)
        cls.prepared,cls.short,cls.good=cls.fixtures['dual']
    def check(self,text,prepared=None):return verify(text,prepared or self.prepared,'simulation')
    def test_three_configs(self):
        for prepared,short,good in self.fixtures.values():
            result=self.check(good,prepared);self.assertFalse(result['hardware_measurement'])
            self.assertFalse(any(x['reportable_coremark'] for x in result['results']['runs']))
    def test_micro_ipc(self):self.assertAlmostEqual(self.check(self.good)['microbenchmark']['ipc'],34818/18503)
    def test_invalid_mutations(self):
        header=next(x for x in self.good.splitlines() if x.startswith('ISSUE_CFG='))
        micro=next(x for x in self.good.splitlines() if x.startswith('DUAL_CHECK'))
        mutations={
            'missing_issue':self.good.replace(header,''),'duplicate_issue':self.good.replace(header,header+'\n'+header),
            'wrong_width':self.good.replace('ISSUE_WIDTH=2','ISSUE_WIDTH=1'),'wrong_fetch':self.good.replace('FETCH_WORDS=2','FETCH_WORDS=1'),
            'wrong_raw_cfg':self.good.replace('d1000003','d1000002'),'missing_micro':self.good.replace(micro,''),
            'duplicate_micro':self.good.replace(micro,micro+'\n'+micro),'wrong_instret':self.good.replace('instret=34818','instret=34817'),
            'zero_pairs':self.good.replace('pairs=16377','pairs=0'),'excess_pairs':self.good.replace('pairs=16377','pairs=34818'),
            'zero_cycles':self.good.replace('cycles=18503','cycles=0'),'ipc_not_dual':self.good.replace('cycles=18503','cycles=34818'),
            'wrong_micro_iterations':self.good.replace('iterations=1024','iterations=1023'),'micro_fail':self.good.replace('DUAL_CHECK PASS','DUAL_CHECK FAIL'),
            'wrong_build':self.good.replace('DUAL1_BOARD','FRONT1_BOARD'),'wrong_misa':self.good.replace('40001100','40000100'),
            'wrong_front':self.good.replace('FETCH=4','FETCH=1'),'wrong_impl':self.good.replace('0003050d','00030509'),
            'wrong_flags':self.good.replace('-march=rv32im_','-march=rv32i_'),'bad_crc':self.good.replace('list=e714','list=0000'),
            'short':self.short,'truncated':self.good.rsplit('CM_READY',1)[0],
            'incomplete_pair':self.good[:self.good.index('CM_BEGIN mode=validation')],
            'duplicate_begin':self.good+'\nCM_BEGIN mode=performance\nCM_READY\n',
            'checks_after_run':self.good.replace(micro,'')+micro+'\nCM_READY\n',
        }
        for name,text in mutations.items():
            with self.subTest(name=name),self.assertRaises((AssertionError,ValueError)):self.check(text)
    def test_scalar_rejects_nonzero_pairs(self):
        p,_,good=self.fixtures['scalar']
        with self.assertRaises(AssertionError):self.check(good.replace('pairs=0','pairs=1'),p)
if __name__=='__main__':unittest.main()
