"""Bad-data rejection checks. Synthetic long runs are never board evidence."""
import copy,json,re,sys,unittest
from pathlib import Path
P=Path(__file__).resolve().parents[1]; sys.path.insert(0,str(P/'scripts'))
from verify_m_log import verify

@unittest.skipUnless((P/'reports/final_coremark/dual/simulation.json').exists(), 'Historical DUAL1 fixtures; current release uses test_evolve_log')
class LogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.prepared=json.loads((P/'reports/final_coremark/dual/simulation.json').read_text())['prepared']
        text=(P/'reports/final_coremark/dual/coremark_uart.txt').read_text()
        begin=text.index('CM_BEGIN '); prefix=text[:begin]
        runs=re.findall(r'(CM_BEGIN .*?CM_READY)',text,re.S)
        assert len(runs)==4
        cls.short=prefix+runs[2]+'\n'+runs[3]+'\n'
        cls.good=re.sub(r'(?<!\w)iterations=8\b','iterations=2048',cls.short)
        cls.good=cls.good.replace('requested_iterations=8','requested_iterations=2048')
        cls.good=re.sub(r'(?<!\w)cycles=\d+', 'cycles=300000000',cls.good)
        cls.good=cls.good.replace('time_ok=0 score_valid=0','time_ok=1 score_valid=1')
    def accept(self,text): return verify(text,self.prepared,'native','simulation')
    def test_synthetic_positive_not_hardware(self): self.assertFalse(self.accept(self.good)['hardware_measurement'])
    def test_short_rejected(self):
        with self.assertRaises(AssertionError): self.accept(self.short)
    def test_wrong_hardware(self):
        with self.assertRaises(AssertionError): self.accept(self.good.replace('MISA=40001100','MISA=40000100'))
    def test_wrong_software_isa(self):
        with self.assertRaises(AssertionError): self.accept(self.good.replace('-march=rv32im_', '-march=rv32i_'))
    def test_missing_boot_test(self):
        with self.assertRaises(AssertionError): self.accept(self.good.replace('M_CHECK PASS vectors=128 instructions=8',''))
    def test_truncated_tail(self):
        with self.assertRaises(AssertionError): self.accept(self.good.rsplit('CM_READY',1)[0])
    def test_bad_crc(self):
        with self.assertRaises((AssertionError,ValueError)): self.accept(self.good.replace('list=e714','list=0000'))
    def test_incomplete_pair(self):
        with self.assertRaises(AssertionError): self.accept(self.good[:self.good.index('CM_BEGIN mode=validation')])
    def test_duplicate_begin(self):
        with self.assertRaises(AssertionError): self.accept(self.good+'\nCM_BEGIN mode=performance\nCM_READY\n')
if __name__=='__main__': unittest.main()
