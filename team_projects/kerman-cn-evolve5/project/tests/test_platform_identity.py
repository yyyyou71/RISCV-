import copy,sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from platform_identity import check_runs,expected_identity,parse_identity
PREP={'clock_hz':25000000,'caches':{'icache_enabled':True,'dcache_enabled':True,'bytes_each':1024,'line_word_bits':2,'set_bits':5},
      'backend':{'kind':'shared_burst','line_bursts':True,'first_wait_cycles':0,'beat_gap_cycles':0},
      'branch_prediction':{'enabled':True,'entries':32,'implementation_id':0x20501}}
HW='HW_ID=43414333 HW_CFG=0000001F CLOCK=25000000 CACHE_BYTES=1024 LINE_BYTES=16 SETS=32 BP_ENTRIES=32 WAIT=0 GAP=0'
BOOT='RV32I COREMARK 1.0\nBUILD=CACHE3_BOARD\nBP_ENABLE=1 BP_ENTRIES=32 IMPL_ID=00020501\n'+HW+'\n'
RUN='CM_BEGIN mode=performance\nCompiler flags : FLAGS\n'
def check(text): return check_runs(text,PREP,'CACHE3_BOARD','FLAGS')
class IdentityTests(unittest.TestCase):
    def test_valid(self): self.assertTrue(check(BOOT+RUN)['identity_passed'])
    def test_three_variants(self):
        for enabled,burst,flags in ((1,1,31),(1,0,23),(0,1,28)):
            cfg=copy.deepcopy(PREP); cfg['caches']['icache_enabled']=cfg['caches']['dcache_enabled']=enabled; cfg['backend']['line_bursts']=burst
            self.assertEqual(expected_identity(cfg)['HW_CFG'],flags)
    def test_lowercase_hex(self): self.assertEqual(parse_identity(HW.lower().replace('hw_', 'HW_')),None); self.assertEqual(parse_identity(HW.replace('1F','1f')),expected_identity(PREP))
    def test_missing_identity(self): self.assertFalse(check(BOOT.replace(HW,'')+RUN)['identity_passed'])
    def test_missing_boot(self): self.assertFalse(check(BOOT.replace('RV32I COREMARK 1.0','')+RUN)['identity_passed'])
    def test_reset_drops_identity(self): self.assertFalse(check(BOOT+RUN+'RV32I COREMARK 1.0\nBUILD=CACHE3_BOARD\n'+RUN)['identity_passed'])
    def test_wrong_fields(self):
        for old,new in [('0000001F','0000001C'),('CLOCK=25000000','CLOCK=50000000'),('CACHE_BYTES=1024','CACHE_BYTES=512'),('WAIT=0','WAIT=8')]:
            with self.subTest(old=old): self.assertFalse(check(BOOT.replace(old,new)+RUN)['identity_passed'])
    def test_junk_field_rejected(self): self.assertIsNone(parse_identity(HW.replace('CLOCK=25000000','CLOCK=25000000oops')))
    def test_duplicate_field_rejected(self): self.assertIsNone(parse_identity(HW+' HW_CFG=0000001F'))
    def test_mixed_variants_rejected(self): self.assertFalse(check(BOOT+RUN+BOOT.replace('0000001F','00000017')+RUN)['identity_passed'])
    def test_old_build_rejected(self): self.assertFalse(check(BOOT.replace('CACHE3_BOARD','CACHE2_BURST')+RUN)['identity_passed'])
    def test_wrong_bp_rejected(self): self.assertFalse(check(BOOT.replace('BP_ENABLE=1','BP_ENABLE=0')+RUN)['identity_passed'])
    def test_flags_rejected(self): self.assertFalse(check(BOOT+RUN.replace('FLAGS','DIFFERENT'))['flags_passed'])
if __name__=='__main__': unittest.main()
