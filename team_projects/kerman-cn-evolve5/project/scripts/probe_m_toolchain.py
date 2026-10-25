"""Check acceptance, assembly, and generated instructions separately."""
import json,subprocess
from pathlib import Path
from regress import PROJECT
from build_coremark import DEFAULT_GCC
build=PROJECT.parents[1]/'work/dual1_toolchain_final'; build.mkdir(exist_ok=True)
source=build/'probe.c'; source.write_text('unsigned f(unsigned a,unsigned b){return a*b;}\nunsigned g(unsigned a,unsigned b){return a/b;}\n')
checks=[]
for isa in ('rv32i_zmmul_zicsr2p0','rv32im_zicsr2p0'):
    asm=build/(isa+'.s'); obj=build/(isa+'.o')
    def call(*args):
        r=subprocess.run([str(x) for x in args],capture_output=True,text=True,errors='replace')
        return r.returncode,r.stdout+r.stderr
    cs,msg=call(DEFAULT_GCC,'-march='+isa,'-mabi=ilp32','-O2','-S',source,'-o',asm)
    co,omsg=call(DEFAULT_GCC,'-march='+isa,'-mabi=ilp32','-O2','-c',source,'-o',obj)
    output=asm.read_text() if cs==0 else ''
    checks.append(dict(isa=isa,compiler_accepted=cs==0,object_assembled=co==0,
                       emits_native_mul='\tmul\t' in output,emits_native_divu='\tdivu\t' in output,
                       calls_software_mul='__mulsi3' in output,assembly=output,diagnostics=msg+omsg))
assert checks[1]['object_assembled'] and checks[1]['emits_native_mul'] and checks[1]['emits_native_divu']
record={'gcc':str(DEFAULT_GCC),'checks':checks,'choice':'RV32IM_Zicsr',
        'reason':'Existing compiler emits native M instructions only for RV32IM; complete divider avoids silently incomplete M hardware.'}
(PROJECT/'reports/toolchain_probe_final.json').write_text(json.dumps(record,indent=2))
print(json.dumps(checks,indent=2))
