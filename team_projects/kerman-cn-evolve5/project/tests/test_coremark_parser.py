import sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from parse_coremark import parse_text

def log(mode='performance',cycles=250000000,crc_ok=1,clock=25000000):
    valid=mode=='validation'; s=13333 if valid else 0
    a,b,c=('e3c1','0747','8d84') if valid else ('e714','1fd7','8e3a')
    t=int(cycles>=clock*10)
    return (f'CM_BEGIN mode={mode} requested_iterations=100 clock_hz={clock} data_size=2000\n'
            f'seedcrc : 0x{"18f2" if valid else "e9f5"}\n'
            f'CM_RESULT mode={mode} iterations=100 cycles={cycles} clock_hz={clock} tick_unit=us '
            f'seed1={s} seed2={s} seed3=102 data_size=2000 contexts=1 crc_ok={crc_ok} time_ok={t} score_valid={crc_ok*t} '
            f'list={a} matrix={b} state={c} final=1234\n')

class ParserTests(unittest.TestCase):
    def test_exact_ten_seconds_with_both_seeds(self):
        result=parse_text(log()+log('validation'),'board',2000)
        self.assertTrue(result['both_standard_seed_sets_valid'])
        self.assertTrue(result['runs'][0]['reportable_coremark'])
        self.assertEqual(result['runs'][0]['iterations_per_second'],'10')
        self.assertEqual(result['runs'][0]['coremark_per_mhz'],'0.4')
        self.assertEqual(result['runs'][0]['coremark_per_lut'],'0.005')
        self.assertFalse(result['runs'][1]['reportable_coremark'])
    def test_one_cycle_short(self):
        row=parse_text(log(cycles=249999999),'board')['runs'][0]
        self.assertFalse(row['duration_valid']); self.assertIsNone(row['iterations_per_second'])
    def test_missing_validation(self):
        self.assertFalse(parse_text(log(),'board')['runs'][0]['reportable_coremark'])
    def test_simulation_is_not_board_score(self):
        result=parse_text(log()+log('validation'),'simulation')
        self.assertFalse(any(r['reportable_coremark'] for r in result['runs']))
    def test_bad_crc_cannot_claim_pass(self):
        with self.assertRaises(ValueError): parse_text(log().replace('list=e714','list=0000'))
    def test_wrong_clock_rejected(self):
        with self.assertRaises(ValueError): parse_text(log(clock=50000000))
    def test_missing_begin_rejected(self):
        with self.assertRaises(ValueError): parse_text(log().split('\n',1)[1])
    def test_requested_iterations_must_match(self):
        with self.assertRaises(ValueError): parse_text(log().replace('requested_iterations=100','requested_iterations=512'))
    def test_nonstandard_size_rejected(self):
        with self.assertRaises(ValueError): parse_text(log().replace('data_size=2000','data_size=6000'))
    def test_flag_domain_rejected(self):
        with self.assertRaises(ValueError): parse_text(log().replace('score_valid=1','score_valid=2'))
    def test_unit_rejected(self):
        with self.assertRaises(ValueError): parse_text(log().replace('tick_unit=us','tick_unit=cycles'))
    def test_cycle_count_over_32bits(self):
        result=parse_text(log(cycles=4294967300)+log('validation',cycles=4294967300),'board')
        self.assertEqual(result['runs'][0]['cycles'],4294967300)
        self.assertEqual(result['runs'][0]['seconds'],'171.798692')
        self.assertTrue(result['runs'][0]['reportable_coremark'])

if __name__=='__main__': unittest.main()
