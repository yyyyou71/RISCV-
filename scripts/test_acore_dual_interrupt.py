import json
import hashlib
from pathlib import Path
import test_interrupt as irq


def main():
    irq.OUT = irq.ROOT / "build/interrupt-dual"
    irq.OUT.mkdir(parents=True, exist_ok=True)
    results = []

    def check(name, body, **kwargs):
        results.append(irq.simulate(name, irq.asm_program(body), dual=1, **kwargs))

    results.append(irq.simulate("csr-instructions", irq.csr_program(), dual=1, irqs=0))
    body = ["li s1,7", "li s2,9", "fence", "inject: addi s1,s1,1", "addi s2,s2,5", "resume: fence"]
    check("paired-alu-boundary", body + irq.check("s1", 8) + irq.check("s2", 14), paired=1)
    body = ["li t0,123", "sw t0,0(s0)", "inject: lw s1,0(s0)", "resume: fence", "addi s2,s1,1"]
    check("load-completes", body + irq.check("s1", 123) + irq.check("s2",124), paired=0)
    body = ["li t0,123", "sw t0,0(s0)", "lw s1,0(s0)", "inject: addi s2,s1,1",
            "addi s3,zero,19", "resume: fence"]
    check("paired-load-use-wait", body + irq.check("s2",124) + irq.check("s3",19),
          stalled=1, min_wait=1, paired=1)
    body = ["li t0,123", "sw t0,0(s0)", "lw s1,0(s0)", "inject: addi s2,zero,19",
            "addi s3,s1,1", "resume: fence"]
    check("secondary-load-use-wait", body + irq.check("s2",19) + irq.check("s3",124),
          stalled=1, min_wait=1, paired=1)
    for operation, enabled, expected, wait in (("mul",0,861,2), ("divu",1,17,30)):
        body = ["li t0,123", "li t1,7", f"inject: {operation} s1,t0,t1", "resume: fence", "addi s2,s1,1"]
        check(operation + "-wait", body + irq.check("s1",expected) + irq.check("s2",expected+1),
              enabled=enabled, stalled=1, min_wait=wait, paired=0)
    for name, skip, resume in (("branch-cold-taken",0,"loop"), ("branch-trained-taken",2,"loop"),
                              ("branch-not-taken",4,"resume")):
        body = ["li s1,5", "loop: addi s1,s1,-1", "inject: bne s1,zero,loop", "resume: fence"]
        check(name, body + irq.check("s1",0), skip=skip, resume=resume, taken=int(skip != 4), paired=0)
    body = ["li t0,0x55", "inject: sw t0,20(t6)", "resume: sw t0,24(t6)"]
    check("mmio-store", body, stores=1, paired=0)
    body = ["inject: jal s3,resume", "link: j fail", "resume:", "la t0,link", "bne s3,t0,fail"]
    check("jal-link", body, paired=0)
    body = ["la s2,first_target", "inject: jalr s3,0(s2)", "link_address: j fail",
            "first_target: la s2,resume", "j inject", "resume:", "la t0,link_address", "bne s3,t0,fail"]
    check("jalr-changing-target", body, skip=1, taken=1, paired=0)
    body = ["li s1,7", "li s2,9", "inject: fence", "csrsi mstatus,8",
            "addi s1,s1,1", "addi s2,s2,5", "resume: fence"]
    results.append(irq.simulate("masked-pending-pair", irq.asm_program(body + irq.check("s1",8) +
                                irq.check("s2",14), enable=False), dual=1, min_wait=2, paired=1))
    destination = irq.ROOT / "reports/acore_dual/interrupts.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    sources = sorted((irq.ROOT / "rtl").glob("*.v")) + sorted((irq.ROOT / "sim/models").glob("*.v"))
    sources += [irq.ROOT / "sim/TB_interrupt.v", Path(__file__).resolve(), irq.ROOT / "scripts/test_interrupt.py"]
    destination.write_text(json.dumps({"cases": results, "source_sha256": {
        path.relative_to(irq.ROOT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}}, indent=2) + "\n")


if __name__ == "__main__":
    main()
