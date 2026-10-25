"""Synthetic long-duration fixtures validate host rejection, never board scores."""
import json,re,sys,unittest
from pathlib import Path
P=Path(__file__).resolve().parents[1];sys.path.insert(0,str(P/'scripts'))
from verify_dual_log import verify
class EvolveLogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root=P/'reports/mul_pair_lto_v2'
        cls.prepared=json.loads((root/'simulation.json').read_text(encoding='utf-8'))['prepared']
        text=(root/'coremark_uart.txt').read_text(encoding='utf-8')
        runs=re.findall(r'(CM_BEGIN .*?CM_READY)',text,re.S)
        cls.short=text[:text.index('CM_BEGIN ')]+runs[2]+'\n'+runs[3]+'\n'
        cls.good=re.sub(r'(?<!\w)iterations=8\b','iterations=2048',cls.short).replace('requested_iterations=8','requested_iterations=2048')
        cls.good=re.sub(r'(?m)^(CM_RESULT .*?cycles=)\d+',r'\g<1>300000000',cls.good).replace('time_ok=0 score_valid=0','time_ok=1 score_valid=1')
    def check(self,s):return verify(s,self.prepared,'simulation')
    def test_positive_is_simulation(self):
        r=self.check(self.good);self.assertFalse(r['hardware_measurement']);self.assertEqual(r['stage'],'EVOLVE5')
    def test_rejections(self):
        headers={prefix:next(x for x in self.good.splitlines() if x.startswith(prefix)) for prefix in ('BP_ENABLE=','BUILD=','ISSUE_CFG=','FRONT_CFG=','DUAL_CHECK')}
        bad={
          'short':self.short,'truncated':self.good.rsplit('CM_READY',1)[0],
          'old_hw':self.good.replace('000328ff','000308ff'),'wrong_build':self.good.replace('EVOLVE1_BOARD','DUAL1_BOARD'),
          'flags':self.good.replace('-flto','-fno-lto'),'bad_crc':self.good.replace('list=e714','list=0000'),
          'wrong_clock':self.good.replace('clock_hz=25000000','clock_hz=50000000'),
          'wrong_instret':self.good.replace('instret=34818','instret=34817'),
          'wrong_front':self.good.replace('FETCH=4','FETCH=1'),
          'incomplete_pair':self.good[:self.good.index('CM_BEGIN mode=validation')],
        }
        for prefix,line in headers.items():
            bad['missing_'+prefix]=self.good.replace(line,'')
            bad['duplicate_'+prefix]=self.good.replace(line,line+'\n'+line)
        for name,text in bad.items():
            with self.subTest(name=name),self.assertRaises((AssertionError,ValueError)):self.check(text)
if __name__=='__main__':unittest.main()
