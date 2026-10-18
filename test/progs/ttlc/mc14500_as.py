#!/usr/bin/env python3
"""The TTLC (MC14500B) assembler.

Two output formats:
  slots (the default; the ttsky26d chip, ttlc_fetch.v): 12-bit instructions
        {address[7:0], opcode[3:0]}, four to a group of three 16-bit words
        (slot k of group g is bits [12k+11:12k] of the 48-bit group, word 3g
        at the low end).  jmp takes two slots, the second holding the 12-bit
        target group; the pair stays inside a group.  Every label starts a
        group (slot 0), padded with nop (= or 137, the constant-0 bit: RR is
        unchanged); a skz is moved past any padding so that it still skips
        the instruction after it.  The PC is {group, slot}, an instruction
        index for straight code.
  words (TT07): one 16-bit word {address[11:0], opcode[3:0]} per
        instruction, a jmp's word holding its 12-bit target address.

Syntax as before: labels end with ':', '//' and /* */ comments, 'include
<file>', '#define NAME expr', 'enum { A, B = 3, C };', arguments are
expressions over the defines.  The .hex beside the source has '@0' then
one word a line as 'lo hi' bytes (--hexWidth 2: 'XXXX').
"""
import argparse
from pathlib import Path

OPS = {"NOPO": 0x0, "LD": 0x1, "LDC": 0x2, "AND": 0x3, "ANDC": 0x4, "OR": 0x5,
       "ORC": 0x6, "XNOR": 0x7, "STO": 0x8, "STOC": 0x9, "IEN": 0xA, "OEN": 0xB,
       "JMP": 0xC, "RTN": 0xD, "SKZ": 0xE, "NOPF": 0xF}
NOP_ADDR = 137                    # read_values[137] is 0: 'or 137' leaves RR alone


class Parser:
    def __init__(self, fmt="slots", arg_bits=12):
        self.fmt = fmt
        self.arg_bits = 8 if fmt == "slots" else arg_bits
        self.mask = (1 << self.arg_bits) - 1
        self.items = []               # ("inst", op, arg or label text, file, line) / ("label", name)
        self.defines = {}
        self.labels = {}
        self.enum_val = 0
        self.errors = 0
        self.filename = ""
        self.line_no = 0

    # ---------------------------------------------------------------- parsing
    def error(self, msg):
        print(f"{self.filename}:{self.line_no}: {msg}")
        self.errors += 1

    def evaluate(self, expr, names=None):
        return eval(expr, {}, names if names is not None else self.defines)

    def parse_enum(self, line):
        line = line.strip(",").strip()
        if not line:
            return
        if "=" in line:
            name, val = [i.strip() for i in line.split("=")]
            self.enum_val = self.evaluate(val)
            self.defines[name] = self.enum_val
        else:
            self.defines[line] = self.enum_val
        self.enum_val += 1

    def parse_instruction(self, line):
        parts = line.split()
        if parts[0] == "#define":
            self.defines[parts[1]] = self.evaluate(" ".join(parts[2:]))
            return
        name = parts[0].upper()
        if name == "NOP":
            self.items.append(("inst", OPS["OR"], str(NOP_ADDR), self.filename, self.line_no))
            return
        if name not in OPS:
            self.error(f"Unsupported instruction: {parts[0]}")
            return
        op = OPS[name]
        arg = None
        if 0 < op < 0xD:
            if len(parts) < 2:
                self.error(f"Expected argument to {parts[0]}")
                return
            arg = " ".join(parts[1:])
        self.items.append(("inst", op, arg, self.filename, self.line_no))

    def parse_file(self, filename):
        old = (self.filename, self.line_no)
        self.filename, self.line_no = filename, 0
        in_comment = 0
        in_enum = False
        try:
            with open(filename) as f:
                for line in f:
                    self.line_no += 1
                    line = line.strip()
                    if "/*" in line:
                        in_comment += 1
                    if "*/" in line:
                        in_comment -= 1
                        continue
                    if "//" in line:
                        line = line[:line.find("//")].strip()
                    if in_comment > 0:
                        continue
                    if line.startswith("enum"):
                        in_enum = True
                        continue
                    if in_enum:
                        if "};" in line:
                            in_enum = False
                        else:
                            self.parse_enum(line)
                        continue
                    if line.endswith(":") or (":" in line and not line.split()[0].startswith("#")):
                        self.items.append(("label", line[:line.find(":")].strip()))
                        continue
                    if line.startswith("include"):
                        name = line.split(None, 1)[1].strip().strip('"<>')
                        self.parse_file(name)
                        continue
                    if line:
                        self.parse_instruction(line)
        except FileNotFoundError:
            self.error(f'File "{filename}" not found')
        self.filename, self.line_no = old

    # ----------------------------------------------------------------- layout
    def layout(self):
        """Resolve labels and lay the instructions out.  Returns a list of
        (index, word_or_slot_value, text) and the words."""
        if self.fmt == "words":
            return self.layout_words()
        return self.layout_slots()

    def arg_value(self, op, arg, names, file, line):
        try:
            return self.evaluate(arg, names)
        except NameError as e:
            print(f"{file}:{line}: {e}")
            self.errors += 1
            return 0

    def layout_words(self):
        addr = 0
        for it in self.items:
            if it[0] == "label":
                self.labels[it[1]] = addr
            else:
                addr += 1
        words = []
        listing = []
        for it in self.items:
            if it[0] == "label":
                continue
            _, op, arg, file, line = it
            if op == 0xC:
                v = self.arg_value(op, arg, self.labels, file, line) & 0xFFF
            elif arg is not None:
                v = self.arg_value(op, arg, self.defines, file, line) & self.mask
            else:
                v = 0
            words.append((v << 4) | op)
            listing.append((len(words) - 1, words[-1], f"{self.mnemonic(op)} {arg or ''}".strip()))
        return listing, words

    def mnemonic(self, op):
        return [k for k, v in OPS.items() if v == op][0].lower()

    def layout_slots(self):
        # first pass: slot indexes (labels on group boundaries, jmp pairs
        # inside a group, skz kept before the instruction it skips)
        slots = []                    # (op, arg_text or None, file, line, is_target_slot)
        NOP = ("inst", OPS["OR"], str(NOP_ADDR), "", 0)

        def emit(it, target=False):
            slots.append((it[1], it[2], it[3], it[4], target))

        def pad_to(boundary):
            # pad with nops to the next multiple of `boundary` slots... keeping
            # a trailing skz adjacent to what follows it
            trailing_skz = slots and slots[-1][0] == 0xE and not slots[-1][4]
            if trailing_skz:
                skz = slots.pop()
            while len(slots) % 4 != 0 if boundary == 4 else len(slots) % 4 == 3:
                emit(NOP)
            if trailing_skz:
                slots.append(skz)
                # the skz itself may now sit in slot 3 before a jmp pair: the
                # caller checks again

        for it in self.items:
            if it[0] == "label":
                if len(slots) % 4 != 0:
                    pad_to(4)
                self.labels[it[1]] = len(slots) // 4
                continue
            if it[1] == 0xC:
                # the pair must not straddle a group
                while len(slots) % 4 == 3:
                    pad_to(3)
                    if len(slots) % 4 == 3:
                        # a skz landed in slot 3: put a nop before it too
                        skz = slots.pop()
                        emit(NOP)
                        slots.append(skz)
                emit(it)
                emit(("inst", 0, it[2], it[3], it[4]), target=True)
            else:
                emit(it)
        # second pass: values
        values = []
        listing = []
        for i, (op, arg, file, line, target) in enumerate(slots):
            if target:
                v = self.arg_value(0xC, arg, self.labels, file, line) & 0xFFF
                values.append(v)
                listing.append((i, v, f"    -> group {v}"))
                continue
            if op == 0xC:
                values.append(0xC)
                listing.append((i, 0xC, f"jmp {arg}"))
                continue
            a = self.arg_value(op, arg, self.defines, file, line) & self.mask if arg is not None else 0
            values.append((a << 4) | op)
            listing.append((i, values[-1], f"{self.mnemonic(op)} {arg or ''}".strip()))
        while len(values) % 4:
            values.append((NOP_ADDR << 4) | OPS["OR"])
        words = []
        for g in range(0, len(values), 4):
            group = sum(values[g + k] << (12 * k) for k in range(4))
            words += [(group >> 0) & 0xFFFF, (group >> 16) & 0xFFFF, (group >> 32) & 0xFFFF]
        return listing, words

    # ------------------------------------------------------------------ output
    def write_hex(self, source, words, hex_width):
        out = Path(source).with_suffix(".hex")
        with open(out, "w") as f:
            print("@0", file=f)
            for w in words:
                print(f"{w:04X}" if hex_width == 2 else f"{w & 0xFF:02X} {w >> 8:02X}", file=f)
        return out


def main():
    ap = argparse.ArgumentParser(description="TTLC (MC14500B) assembler")
    ap.add_argument("filename")
    ap.add_argument("--format", choices=("slots", "words"), default="slots",
                    help="slots: 12-bit slots, four to three words (ttsky26d); words: one word an instruction (TT07)")
    ap.add_argument("--bitWidth", type=int, default=12, help="the address width of the words format")
    ap.add_argument("--hexWidth", type=int, default=1, help="1: 'lo hi' bytes a word; 2: one 4-digit word a line")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()
    p = Parser(args.format, args.bitWidth)
    p.parse_file(args.filename)
    listing, words = p.layout()
    if p.errors:
        return 1
    out = p.write_hex(args.filename, words, args.hexWidth)
    if not args.quiet:
        for i, v, text in listing:
            where = f"{i // 4:4d}.{i % 4}" if args.format == "slots" else f"{i:6d}"
            print(f"{where}  {v:03X}  {text}")
    n = len(listing) - sum(1 for _, _, t in listing if t.startswith("    ->"))
    print(f"{out}: {n} instructions, {len(words)} words" + (f" ({len(words) // 3} groups)" if args.format == "slots" else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
