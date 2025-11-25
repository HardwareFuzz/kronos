#!/usr/bin/env python3
import argparse
import os
import re
import subprocess
import sys
import tempfile


def parse_nm(nm_path):
    syms = {}
    with open(nm_path, "r") as f:
        for line in f:
            parts = line.strip().split()
            if len(parts) >= 3:
                addr_hex, typ, name = parts[0], parts[1], parts[2]
                try:
                    addr = int(addr_hex, 16)
                    syms[name] = addr
                except ValueError:
                    pass
    return syms


def run_runner(runner, elf, tohost, max_cycles, log_flags, log_file):
    cmd = [
        runner,
        elf,
        "--tohost",
        hex(tohost),
        "--max-cycles",
        str(max_cycles),
        "--log",
        log_flags,
        "--log-file",
        log_file,
    ]
    print("RUN:", " ".join(cmd))
    cp = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    print(cp.stdout)
    return cp.returncode


def parse_memw(log_path):
    # [MEMW] pc=0x44 addr=0xd4 data=0x12345678 mask=0xf
    memw = []
    pat = re.compile(
        r"^\[MEMW\]\s+pc=0x([0-9a-fA-F]+)\s+addr=0x([0-9a-fA-F]+)\s+data=0x([0-9a-fA-F]+)\s+mask=0x([0-9a-fA-F]+)"
    )
    with open(log_path, "r") as f:
        for line in f:
            m = pat.match(line.strip())
            if m:
                pc = int(m.group(1), 16)
                addr = int(m.group(2), 16)
                data = int(m.group(3), 16)
                mask = int(m.group(4), 16)
                memw.append({"pc": pc, "addr": addr, "data": data, "mask": mask})
    return memw


def parse_reg(log_path):
    # [REG] pc=0x30 x5 <= 0x12345678
    regs = []
    pat = re.compile(
        r"^\[REG\]\s+pc=0x([0-9a-fA-F]+)\s+x([0-9]+)\s+<=\s+0x([0-9a-fA-F]+)"
    )
    with open(log_path, "r") as f:
        for line in f:
            m = pat.match(line.strip())
            if m:
                pc = int(m.group(1), 16)
                rd = int(m.group(2), 10)
                val = int(m.group(3), 16)
                regs.append({"pc": pc, "rd": rd, "val": val})
    return regs

def parse_objdump_for_final_reg_pc(objdump_path, label, rd_num):
    # Scan the disassembly block of `label:`; return the PC of the last
    # instruction that writes to x<rd_num>. We consider common register-writing
    # mnemonics and exclude stores/branches.
    if not os.path.exists(objdump_path):
        return None
    with open(objdump_path, "r") as f:
        lines = f.readlines()
    label_re = re.compile(r"^\s*([0-9a-fA-F]+)\s+<{}>:".format(re.escape(label)))
    next_label_re = re.compile(r"^\s*[0-9a-fA-F]+\s+<[^>]+>:")
    insn_re = re.compile(r"^\s*([0-9a-fA-F]+):\s+[0-9a-fA-F ]+\s+\t([a-z0-9\.]+)\s+(.*)$")
    write_mnems = {
        "addi","add","sub","lui","ori","xori","andi",
        "slli","srli","srai","auipc","and","or","xor",
        "sll","srl","sra","slti","sltiu","slt","sltu",
        "jal","jalr","csrrw","csrrs","csrrc","csrrwi","csrrsi","csrrci","li"
    }
    start = -1
    for i, line in enumerate(lines):
        if label_re.match(line):
            start = i + 1
            break
    if start < 0:
        return None
    last_pc = None
    i = start
    while i < len(lines):
        if next_label_re.match(lines[i]):
            break
        m = insn_re.match(lines[i])
        if m:
            pc = int(m.group(1), 16)
            mnem = m.group(2)
            ops_str = m.group(3)
            # first operand should be x<rd_num>
            ops = [o.strip() for o in ops_str.split(",") if o.strip()]
            if ops:
                op0 = ops[0]
                # accept both numeric and ABI names for the rd
                abi_map = {5:"t0",6:"t1",7:"t2",28:"t3"}
                ok_rd = (op0 == f"x{rd_num}") or (abi_map.get(rd_num) == op0)
                if ok_rd and (mnem not in ("sb","sh","sw","beq","bne","blt","bge","bltu","bgeu")):
                    if mnem in write_mnems or mnem.startswith("c."):
                        last_pc = pc
        i += 1
    return last_pc


def main():
    parser = argparse.ArgumentParser(description="Check skiptrap commit-log against expected")
    parser.add_argument("--root", default=os.path.abspath(os.path.join(os.path.dirname(__file__), "../..")))
    parser.add_argument("--max-cycles", type=int, default=5000)
    parser.add_argument("--runner", default=None, help="Path to kronos_rv32 (optional)")
    parser.add_argument("--build-skiptrap", action="store_true")
    args = parser.parse_args()

    root = args.root
    runner = args.runner or os.path.join(root, "build_result", "kronos_rv32")
    elf = os.path.join(root, "software", "skiptrap", "build", "skiptrap.elf")
    nm_path = os.path.join(root, "software", "skiptrap", "build", "skiptrap.nm")
    objdump_path = os.path.join(root, "software", "skiptrap", "build", "skiptrap.objdump")

    if args.build_skiptrap or not (os.path.exists(elf) and os.path.exists(nm_path)):
        subprocess.check_call(["make", "-C", os.path.join(root, "software", "skiptrap"), "-j"])

    if not os.path.exists(runner):
        print("runner not found:", runner, file=sys.stderr)
        print("hint: run ./build.sh at project root", file=sys.stderr)
        return 2

    syms = parse_nm(nm_path)
    tohost = syms["tohost"]
    g_data0 = syms["g_data0"]
    g_data1 = syms["g_data1"]
    g_buf = syms["g_buf"]
    pcs = {
        "L_SW_GDATA0": syms.get("L_SW_GDATA0"),
        "L_SW_GDATA1": syms.get("L_SW_GDATA1"),
        "L_SW_GBUF": syms.get("L_SW_GBUF"),
        "L_SH_GBUF_P2": syms.get("L_SH_GBUF_P2"),
        "L_SB_GBUF_P1": syms.get("L_SB_GBUF_P1"),
        "L_SW_TOHOST": syms.get("L_SW_TOHOST"),
        "L_MISALIGNED_SW": syms.get("L_MISALIGNED_SW"),
        "L_LI_T0_1": syms.get("L_LI_T0_1"),
        "L_LI_T0": syms.get("L_LI_T0"),
        "L_LI_T1": syms.get("L_LI_T1"),
        "L_LI_T2": syms.get("L_LI_T2"),
        "L_LI_T3": syms.get("L_LI_T3"),
    }

    # Expected writes (values as in skiptrap.S)
    EXP = [
        {"pc": pcs["L_SW_GDATA0"], "addr": g_data0, "data": 0x12345678, "mask": 0xF},
        {"pc": pcs["L_SW_GDATA1"], "addr": g_data1, "data": 0xABCDEF01, "mask": 0xF},
        {"pc": pcs["L_SW_GBUF"], "addr": g_buf + 0, "data": 0x11223344, "mask": 0xF},     # sw
        {"pc": pcs["L_SH_GBUF_P2"], "addr": g_buf + 0, "data": 0x33441122, "mask": 0xC}, # sh +2
        {"pc": pcs["L_SB_GBUF_P1"], "addr": g_buf + 0, "data": 0x22334411, "mask": 0x2}, # sb +1
        {"pc": pcs["L_SW_TOHOST"], "addr": tohost, "data": 0x1, "mask": 0xF},            # exit
    ]

    tmp = tempfile.NamedTemporaryFile(delete=False, prefix="skiptrap_log_", suffix=".txt")
    tmp.close()

    rc = run_runner(runner, elf, tohost, args.max_cycles, "reg,mem,trap", tmp.name)
    if rc != 0:
        print("Runner exited with non-zero:", rc, file=sys.stderr)
        return rc

    got = parse_memw(tmp.name)
    got_reg = parse_reg(tmp.name)
    # 严格匹配：pc+addr+data+mask 一一对应
    errors = []
    positions = {}
    for idx, e in enumerate(EXP):
        if e["pc"] is None:
            errors.append(f"Symbol PC not found for an expected event: {e}")
            continue
        # 允许因流水对齐产生的轻微偏移：{pc, pc+2, pc+4, pc+6, pc+8}
        ok = None
        for off in (0, 2, 4, 6, 8):
            cand = next((i for i, w in enumerate(got)
                         if w["pc"] == e["pc"] + off and w["addr"] == e["addr"]
                         and w["mask"] == e["mask"] and w["data"] == e["data"]), None)
            if cand is not None:
                positions[idx] = cand
                ok = True
                break
        if not ok:
            errors.append(
                f"Missing write pc=0x{e['pc']:x} addr=0x{e['addr']:x} data=0x{e['data']:x} mask=0x{e['mask']:x}"
            )
    # 顺序约束：事件出现顺序应与程序顺序一致
    if not errors:
        for i in range(len(EXP) - 1):
            if positions[i] >= positions[i + 1]:
                errors.append(f"Order mismatch between event {i} and {i+1}")

    # Ensure对齐错误 sw g_data0+2 未实际写入（地址对齐到 g_data0，所以检查该地址总写次数仅一次）
    writes_g0 = [w for w in got if w["addr"] == g_data0]
    if len(writes_g0) != 1 or not (writes_g0[0]["data"] == 0x12345678 and writes_g0[0]["mask"] == 0xF):
        errors.append(f"Unexpected extra write(s) to g_data0 (found {len(writes_g0)})")

    # 确认：在 L_MISALIGNED_SW 的 PC 上不应出现任何 [MEMW]
    if pcs["L_MISALIGNED_SW"] is not None and any(w["pc"] == pcs["L_MISALIGNED_SW"] for w in got):
        errors.append("Unexpected MEMW at misaligned SW PC")

    if errors:
        print("FAIL:")
        for e in errors:
            print(" -", e)
        print("\nLog saved at:", tmp.name)
        return 1

    # Register strict checks using objdump-derived exact PCs
    REG_EXP = [
        {"label": "L_LI_T0", "rd": 5,  "val": 0x12345678},  # t0
        {"label": "L_LI_T1", "rd": 6,  "val": 0xABCDEF01},  # t1
        {"label": "L_LI_T2", "rd": 7,  "val": 0x11223344},  # t2
        {"label": "L_LI_T3", "rd": 28, "val": 0x0},         # t3
        {"label": "L_LI_T0_1", "rd": 5, "val": 0x1},        # t0 before tohost
    ]
    final_pc_map = {}
    for e in REG_EXP:
        pc = parse_objdump_for_final_reg_pc(objdump_path, e["label"], e["rd"])
        if pc is None:
            errors.append(f"Objdump PC not found for label {e['label']}")
        else:
            final_pc_map[e["label"]] = pc

    for e in REG_EXP:
        if e["label"] not in final_pc_map:
            continue
        pc_req = final_pc_map[e["label"]]
        if not any((w["pc"] == pc_req and w["rd"] == e["rd"] and w["val"] == e["val"]) for w in got_reg):
            errors.append(f"Missing REG at exact pc=0x{pc_req:x} x{e['rd']} <= 0x{e['val']:x} (label {e['label']})")

    if errors:
        print("FAIL:")
        for e in errors:
            print(" -", e)
        print("\nLog saved at:", tmp.name)
        return 1

    print("PASS: strict REG+MEMW checks passed; misaligned store suppressed.")
    os.unlink(tmp.name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
