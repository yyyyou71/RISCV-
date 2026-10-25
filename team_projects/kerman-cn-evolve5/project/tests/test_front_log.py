"""Synthetic long-duration parser tests; never actual board score evidence."""
import json,re,sys,unittest
from pathlib import Path
P=Path(__file__).resolve().parents[1];sys.path.insert(0,str(P/'scripts'))
from verify_front_log import verify,expected_front
@unittest.skipUnless((P/'reports/final_coremark/dual/simulation.json').exists(), 'Historical DUAL1 fixtures; current release uses test_evolve_log')
class FrontLogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root=P/'reports/final_coremark/dual'
        cls.prepared=json.loads((root/'simulation.json').read_text())['prepared']
        text=(root/'coremark_uart.txt').read_text();prefix=text[:text.index('CM_BEGIN ')]
        runs=re.findall(r'(CM_BEGIN .*?CM_READY)',text,re.S)
        cls.short=prefix+runs[2]+'\n'+runs[3]+'\n'
        cls.good=re.sub(r'(?<!\w)iterations=8\b','iterations=2048',cls.short).replace('requested_iterations=8','requested_iterations=2048')
        cls.good=re.sub(r'(?<!\w)cycles=\d+','cycles=300000000',cls.good).replace('time_ok=0 score_valid=0','time_ok=1 score_valid=1')
    def check(self,text):return verify(text,self.prepared,'simulation')
    def test_valid_synthetic_has_no_board_origin(self):self.assertFalse(self.check(self.good)['hardware_measurement'])
    def test_bypass_bit_required(self):
        with self.assertRaises(AssertionError):self.check(self.good.replace('FRONT_CFG=f1540086','FRONT_CFG=f1540082'))
    def test_wrong_depth(self):
        with self.assertRaises(AssertionError):self.check(self.good.replace('FETCH=4','FETCH=2'))
    def test_wrong_ras(self):
        with self.assertRaises(AssertionError):self.check(self.good.replace('RAS=0','RAS=8'))
    def test_missing_front(self):
        with self.assertRaises(AssertionError):self.check(re.sub(r'^FRONT_CFG=.*\n','',self.good,flags=re.M))
    def test_duplicate_front(self):
        line=next(x for x in self.good.splitlines() if x.startswith('FRONT_CFG='))
        with self.assertRaises(AssertionError):self.check(self.good.replace(line,line+'\n'+line))
    def test_wrong_build(self):
        with self.assertRaises(AssertionError):self.check(self.good.replace('DUAL1_BOARD','MEXT1_BOARD'))
    def test_incomplete_validation(self):
        with self.assertRaises(AssertionError):self.check(self.good[:self.good.index('CM_BEGIN mode=validation')])
    def test_missing_last_ready(self):
        with self.assertRaises(AssertionError):self.check(self.good.rsplit('CM_READY',1)[0])
    def test_short_rejected(self):
        with self.assertRaises(AssertionError):self.check(self.short)
    def test_wrong_crc(self):
        with self.assertRaises((AssertionError,ValueError)):self.check(self.good.replace('list=e714','list=0000'))
    def test_cfg_values(self):self.assertEqual(expected_front(self.prepared),[0xf1540086,0,8,0,4,1])
if __name__=='__main__':unittest.main()
