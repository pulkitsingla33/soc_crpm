#!/usr/bin/env python3
"""
rvasm.py - minimal two-pass RV32I + Zicsr assembler (no external toolchain
needed on the lab server). Produces a $readmemh image (one 32-bit word per
line, '@<word address>' records) for soc_ram.

Supported:
  directives : .org <addr>   .word <expr>[,...]   .equ NAME, <expr>   .align 2
  RV32I      : lui auipc jal jalr beq bne blt bge bltu bgeu lb lh lw lbu lhu
               sb sh sw addi slti sltiu xori ori andi slli srli srai add sub
               sll slt sltu xor srl sra or and fence ecall ebreak
  Zicsr      : csrrw csrrs csrrc csrrwi csrrsi csrrci
  privileged : wfi mret
  pseudo     : nop li la mv not neg j jr ret call beqz bnez bltz bgez
               csrr csrw csrs csrc
Usage: python3 rvasm.py input.S output.hex [listing.lst]
"""
import re
import sys

REGS = {f"x{i}": i for i in range(32)}
ABI = ["zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1",
       "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7",
       "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11",
       "t3", "t4", "t5", "t6"]
REGS.update({n: i for i, n in enumerate(ABI)})
REGS["fp"] = 8

CSRS = {"mstatus": 0x300, "misa": 0x301, "mie": 0x304, "mtvec": 0x305,
        "mscratch": 0x340, "mepc": 0x341, "mcause": 0x342, "mtval": 0x343,
        "mip": 0x344, "mcycle": 0xB00, "minstret": 0xB02, "mhartid": 0xF14}

BR = {"beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7}
LD = {"lb": 0, "lh": 1, "lw": 2, "lbu": 4, "lhu": 5}
ST = {"sb": 0, "sh": 1, "sw": 2}
OPI = {"addi": 0, "slti": 2, "sltiu": 3, "xori": 4, "ori": 6, "andi": 7}
SHI = {"slli": (1, 0x00), "srli": (5, 0x00), "srai": (5, 0x20)}
OPR = {"add": (0, 0x00), "sub": (0, 0x20), "sll": (1, 0), "slt": (2, 0),
       "sltu": (3, 0), "xor": (4, 0), "srl": (5, 0), "sra": (5, 0x20),
       "or": (6, 0), "and": (7, 0)}
CSR = {"csrrw": 1, "csrrs": 2, "csrrc": 3, "csrrwi": 5, "csrrsi": 6, "csrrci": 7}


class AsmError(Exception):
    pass


def size_of(mn):
    """Instruction size in bytes (pseudo-ops li/la/call expand to 2 words)."""
    return 8 if mn in ("li", "la") else 4


class Assembler:
    def __init__(self):
        self.sym = {}
        self.lines = []

    # ------------------------------------------------------------ helpers
    def ev(self, expr):
        expr = expr.strip()
        try:
            return int(eval(expr, {"__builtins__": {}}, dict(self.sym)))
        except Exception as e:  # noqa: BLE001
            raise AsmError(f"cannot evaluate '{expr}': {e}")

    @staticmethod
    def reg(r):
        r = r.strip()
        if r not in REGS:
            raise AsmError(f"bad register '{r}'")
        return REGS[r]

    def csr(self, c):
        c = c.strip()
        return CSRS[c] if c in CSRS else self.ev(c)

    @staticmethod
    def chk(v, bits, signed=True):
        lo, hi = (-(1 << (bits - 1)), (1 << (bits - 1)) - 1) if signed else (0, (1 << bits) - 1)
        if not lo <= v <= hi:
            raise AsmError(f"immediate {v} does not fit in {bits} bits")
        return v & ((1 << bits) - 1)

    # ------------------------------------------------------------ encoders
    @staticmethod
    def r(f7, rs2, rs1, f3, rd, op):
        return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

    def i(self, imm, rs1, f3, rd, op):
        return (self.chk(imm, 12) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

    def s(self, imm, rs2, rs1, f3, op):
        imm = self.chk(imm, 12)
        return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1F) << 7) | op

    def b(self, off, rs2, rs1, f3):
        if off & 1:
            raise AsmError("misaligned branch target")
        o = self.chk(off, 13)
        return (((o >> 12) & 1) << 31) | (((o >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | \
               (f3 << 12) | (((o >> 1) & 0xF) << 8) | (((o >> 11) & 1) << 7) | 0x63

    def j(self, off, rd):
        o = self.chk(off, 21)
        return (((o >> 20) & 1) << 31) | (((o >> 1) & 0x3FF) << 21) | (((o >> 11) & 1) << 20) | \
               (((o >> 12) & 0xFF) << 12) | (rd << 7) | 0x6F

    @staticmethod
    def hi_lo(v):
        v &= 0xFFFFFFFF
        lo = v & 0xFFF
        if lo >= 0x800:
            lo -= 0x1000
        hi = ((v - lo) >> 12) & 0xFFFFF
        return hi, lo

    def memop(self, arg):
        m = re.fullmatch(r"(.*)\((\w+)\)", arg.strip())
        if not m:
            raise AsmError(f"bad memory operand '{arg}'")
        off = self.ev(m.group(1)) if m.group(1).strip() else 0
        return off, self.reg(m.group(2))

    # ------------------------------------------------------------ parsing
    def parse(self, text):
        pc = 0
        for n, raw in enumerate(text.splitlines(), 1):
            line = raw.split("#")[0].split("//")[0].strip()
            while True:  # labels
                m = re.match(r"^([A-Za-z_.][\w.]*):\s*(.*)$", line)
                if not m:
                    break
                if m.group(1) in self.sym:
                    raise AsmError(f"line {n}: duplicate label {m.group(1)}")
                self.sym[m.group(1)] = pc
                line = m.group(2)
            if not line:
                continue
            parts = line.split(None, 1)
            mn = parts[0].lower()
            args = [a.strip() for a in parts[1].split(",")] if len(parts) > 1 else []
            if mn == ".equ":
                self.sym[args[0]] = self.ev(args[1])
                continue
            if mn == ".org":
                pc = self.ev(args[0])
                self.lines.append((n, raw, pc, ".org", args))
                continue
            if mn == ".align":
                a = 1 << self.ev(args[0])
                pc = (pc + a - 1) & ~(a - 1)
                self.lines.append((n, raw, pc, ".org", [str(pc)]))
                continue
            self.lines.append((n, raw, pc, mn, args))
            pc += 4 * len(args) if mn == ".word" else size_of(mn)

    def encode(self, pc, mn, a):
        R, E = self.reg, self.ev
        if mn == ".word":
            return [E(x) & 0xFFFFFFFF for x in a]
        if mn == "nop":
            return [self.i(0, 0, 0, 0, 0x13)]
        if mn in ("li", "la"):
            hi, lo = self.hi_lo(E(a[1]))
            rd = R(a[0])
            return [(hi << 12) | (rd << 7) | 0x37, self.i(lo, rd, 0, rd, 0x13)]
        if mn == "mv":
            return [self.i(0, R(a[1]), 0, R(a[0]), 0x13)]
        if mn == "not":
            return [self.i(-1, R(a[1]), 4, R(a[0]), 0x13)]
        if mn == "neg":
            return [self.r(0x20, R(a[1]), 0, 0, R(a[0]), 0x33)]
        if mn == "j":
            return [self.j(E(a[0]) - pc, 0)]
        if mn == "call":
            return [self.j(E(a[0]) - pc, 1)]
        if mn == "jr":
            return [self.i(0, R(a[0]), 0, 0, 0x67)]
        if mn == "ret":
            return [self.i(0, 1, 0, 0, 0x67)]
        if mn in ("beqz", "bnez", "bltz", "bgez"):
            f3 = {"beqz": 0, "bnez": 1, "bltz": 4, "bgez": 5}[mn]
            return [self.b(E(a[1]) - pc, 0, R(a[0]), f3)]
        if mn == "csrr":
            return [(self.csr(a[1]) << 20) | (2 << 12) | (R(a[0]) << 7) | 0x73]
        if mn in ("csrw", "csrs", "csrc"):
            f3 = {"csrw": 1, "csrs": 2, "csrc": 3}[mn]
            return [(self.csr(a[0]) << 20) | (R(a[1]) << 15) | (f3 << 12) | 0x73]
        if mn == "lui":
            return [((E(a[1]) & 0xFFFFF) << 12) | (R(a[0]) << 7) | 0x37]
        if mn == "auipc":
            return [((E(a[1]) & 0xFFFFF) << 12) | (R(a[0]) << 7) | 0x17]
        if mn == "jal":
            if len(a) == 1:
                return [self.j(E(a[0]) - pc, 1)]
            return [self.j(E(a[1]) - pc, R(a[0]))]
        if mn == "jalr":
            if len(a) == 1:
                return [self.i(0, R(a[0]), 0, 1, 0x67)]
            off, rs1 = self.memop(a[1]) if "(" in a[1] else (E(a[2]) if len(a) > 2 else 0, R(a[1]))
            return [self.i(off, rs1, 0, R(a[0]), 0x67)]
        if mn in BR:
            return [self.b(E(a[2]) - pc, R(a[1]), R(a[0]), BR[mn])]
        if mn in LD:
            off, rs1 = self.memop(a[1])
            return [self.i(off, rs1, LD[mn], R(a[0]), 0x03)]
        if mn in ST:
            off, rs1 = self.memop(a[1])
            return [self.s(off, R(a[0]), rs1, ST[mn], 0x23)]
        if mn in OPI:
            return [self.i(E(a[2]), R(a[1]), OPI[mn], R(a[0]), 0x13)]
        if mn in SHI:
            f3, f7 = SHI[mn]
            return [self.r(f7, self.chk(E(a[2]), 5, False), R(a[1]), f3, R(a[0]), 0x13)]
        if mn in OPR:
            f3, f7 = OPR[mn]
            return [self.r(f7, R(a[2]), R(a[1]), f3, R(a[0]), 0x33)]
        if mn in CSR:
            f3 = CSR[mn]
            src = self.chk(E(a[2]), 5, False) if f3 >= 5 else R(a[2])
            return [(self.csr(a[1]) << 20) | (src << 15) | (f3 << 12) | (R(a[0]) << 7) | 0x73]
        if mn == "fence":
            return [0x0FF0000F]
        if mn == "ecall":
            return [0x00000073]
        if mn == "ebreak":
            return [0x00100073]
        if mn == "wfi":
            return [0x10500073]
        if mn == "mret":
            return [0x30200073]
        raise AsmError(f"unknown mnemonic '{mn}'")

    def assemble(self, text):
        self.parse(text)
        image, listing = {}, []
        for n, raw, pc, mn, args in self.lines:
            if mn == ".org":
                continue
            try:
                words = self.encode(pc, mn, args)
            except AsmError as e:
                raise AsmError(f"line {n}: {e}\n    {raw.strip()}")
            for k, w in enumerate(words):
                image[(pc >> 2) + k] = w
                listing.append(f"{pc + 4 * k:08x}: {w:08x}    {raw.strip() if k == 0 else ''}")
        return image, listing


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    asm = Assembler()
    try:
        image, listing = asm.assemble(open(sys.argv[1]).read())
    except AsmError as e:
        print(f"rvasm: error: {e}")
        sys.exit(2)
    with open(sys.argv[2], "w") as f:
        prev = None
        for addr in sorted(image):
            if prev is None or addr != prev + 1:
                f.write(f"@{addr:08x}\n")
            f.write(f"{image[addr]:08x}\n")
            prev = addr
    if len(sys.argv) > 3:
        with open(sys.argv[3], "w") as f:
            f.write("\n".join(listing) + "\n")
    print(f"rvasm: {len(image)} words -> {sys.argv[2]}")


if __name__ == "__main__":
    main()
