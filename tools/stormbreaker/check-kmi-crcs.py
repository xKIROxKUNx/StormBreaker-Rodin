#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""
Verify that a StormBreaker build still satisfies the stock vendor modules' KMI.

Why this exists
---------------
kernel/module/version.c:same_magic() skips the kernel release string when a
module carries symbol CRCs, so a 6.6.89 -> 6.6.142 jump is fine by itself.
What actually gates module loading is the per-symbol CRCs recorded in each
module's __versions section: check_version() refuses the module when a CRC
disagrees with the running kernel's.

So this is the test that decides whether the BORE port was done correctly. If a
single CRC of a symbol a vendor module imports has moved, the device boots with
no WiFi, no touch, nothing -- and it will look like a mysterious hardware bug
rather than an ABI mistake.

Usage
-----
    ./tools/stormbreaker/check-kmi-crcs.py out/Module.symvers <dir-with-stock-.ko> [more dirs...]

  e.g.
    ./tools/stormbreaker/check-kmi-crcs.py out/Module.symvers /tmp/vr/lib/modules

Exit status: 0 = every imported symbol matches (safe to flash),
             1 = mismatch or missing symbol (DO NOT flash),
             2 = usage / input problem.
"""

import os
import re
import struct
import sys


def load_symvers(path):
    """Parse Module.symvers -> {symbol: crc}."""
    crcs = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            parts = line.split()
            if len(parts) < 2:
                continue
            crc, sym = parts[0], parts[1]
            try:
                crcs[sym] = int(crc, 16) & 0xFFFFFFFF
            except ValueError:
                continue
    return crcs


def find_section(data, name):
    """Return (offset, size) of an ELF64 section by name, or None."""
    if data[:4] != b"\x7fELF" or data[4] != 2:
        return None
    little = data[5] == 1
    end = "<" if little else ">"
    e_shoff = struct.unpack_from(end + "Q", data, 0x28)[0]
    e_shentsize = struct.unpack_from(end + "H", data, 0x3A)[0]
    e_shnum = struct.unpack_from(end + "H", data, 0x3C)[0]
    e_shstrndx = struct.unpack_from(end + "H", data, 0x3E)[0]

    def shdr(i):
        off = e_shoff + i * e_shentsize
        sh_name = struct.unpack_from(end + "I", data, off)[0]
        sh_offset = struct.unpack_from(end + "Q", data, off + 0x18)[0]
        sh_size = struct.unpack_from(end + "Q", data, off + 0x20)[0]
        return sh_name, sh_offset, sh_size

    _, str_off, _ = shdr(e_shstrndx)
    target = name.encode()
    for i in range(e_shnum):
        sh_name, sh_offset, sh_size = shdr(i)
        nul = data.index(b"\0", str_off + sh_name)
        if data[str_off + sh_name:nul] == target:
            return sh_offset, sh_size, end
    return None


def module_imports(path):
    """Parse a .ko's __versions section -> {symbol: crc_it_expects}."""
    with open(path, "rb") as fh:
        data = fh.read()
    found = find_section(data, "__versions")
    if not found:
        return {}
    off, size, end = found
    blob = data[off:off + size]
    # struct modversion_info { unsigned long crc; char name[MODULE_NAME_LEN]; }
    # MODULE_NAME_LEN is 64 - sizeof(unsigned long) = 56 on 64-bit.
    entry = 8 + 56
    out = {}
    for i in range(0, len(blob) - entry + 1, entry):
        crc = struct.unpack_from(end + "Q", blob, i)[0] & 0xFFFFFFFF
        raw = blob[i + 8:i + entry]
        name = raw.split(b"\0", 1)[0].decode("ascii", "replace")
        if name:
            out[name] = crc
    return out


def module_exports(path):
    """Symbols a module itself EXPORTS, from __ksymtab_<name> entries in .symtab.

    Vendor modules export to each other, so a symbol the GKI kernel does not
    provide is perfectly fine as long as some other module in the set does.
    Without this, every inter-vendor symbol looks like a missing dependency.
    """
    with open(path, "rb") as fh:
        data = fh.read()
    sym = find_section(data, ".symtab")
    strt = find_section(data, ".strtab")
    if not sym or not strt:
        return set()
    sym_off, sym_size, end = sym
    str_off, _str_size, _ = strt
    out = set()
    entsize = 24  # Elf64_Sym
    for i in range(sym_off, sym_off + sym_size - entsize + 1, entsize):
        name_off = struct.unpack_from(end + "I", data, i)[0]
        if not name_off:
            continue
        try:
            nul = data.index(b"\0", str_off + name_off)
        except ValueError:
            continue
        name = data[str_off + name_off:nul].decode("ascii", "replace")
        if name.startswith("__ksymtab_"):
            out.add(name[len("__ksymtab_"):])
    return out


def vermagic_of(path):
    with open(path, "rb") as fh:
        data = fh.read()
    m = re.search(rb"vermagic=([^\x00]+)", data)
    return m.group(1).decode("ascii", "replace") if m else None


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    symvers_path, ko_dirs = argv[1], argv[2:]
    if not os.path.isfile(symvers_path):
        print(f"not a file: {symvers_path}", file=sys.stderr)
        return 2
    for d in ko_dirs:
        if not os.path.isdir(d):
            print(f"not a directory: {d}", file=sys.stderr)
            return 2

    ours = load_symvers(symvers_path)
    print(f"our kernel exports {len(ours)} versioned symbols")

    kos = []
    for d in ko_dirs:
        for root, _dirs, files in os.walk(d):
            for f in files:
                if f.endswith(".ko"):
                    kos.append(os.path.join(root, f))
    kos.sort()
    if not kos:
        print(f"no .ko files under {', '.join(ko_dirs)}", file=sys.stderr)
        return 2
    print(f"checking {len(kos)} stock modules from "
          f"{len(ko_dirs)} director{'y' if len(ko_dirs) == 1 else 'ies'}\n")

    vermagics = {}
    mismatched = {}   # symbol -> (expected, ours, [modules])
    missing = {}      # symbol -> [modules]
    checked_syms = set()
    no_versions = []
    vendor_exports = set()

    for ko in kos:
        base = os.path.basename(ko)
        vm = vermagic_of(ko)
        if vm:
            vermagics.setdefault(vm, []).append(base)
        vendor_exports |= module_exports(ko)
        imports = module_imports(ko)
        if not imports:
            no_versions.append(base)
            continue
        for sym, want in imports.items():
            checked_syms.add(sym)
            if sym not in ours:
                missing.setdefault(sym, []).append(base)
            elif ours[sym] != want:
                mismatched.setdefault(sym, (want, ours[sym], []))[2].append(base)

    print("vermagic strings seen in the stock modules:")
    for vm, mods in sorted(vermagics.items(), key=lambda kv: -len(kv[1])):
        flags = vm.split(" ", 1)[1] if " " in vm else "(no flags)"
        print(f"  {len(mods):4d} module(s): {vm}")
        print(f"       flags that must match: {flags}")
    print()

    if no_versions:
        print(f"note: {len(no_versions)} module(s) carry no __versions section "
              f"(CONFIG_MODVERSIONS off in their build); same_magic() will then "
              f"compare the full release string and they would be rejected:")
        for m in no_versions[:10]:
            print(f"  - {m}")
        if len(no_versions) > 10:
            print(f"  ... and {len(no_versions) - 10} more")
        print()

    print(f"distinct symbols imported by the stock modules: {len(checked_syms)}")

    rc = 0
    by_vendor = {k: v for k, v in missing.items() if k in vendor_exports}
    unresolved = {k: v for k, v in missing.items() if k not in vendor_exports}

    print(f"symbols the stock modules export to each other: {len(vendor_exports)}")
    print(f"  of the {len(missing)} not provided by our kernel, "
          f"{len(by_vendor)} are resolved by another stock module")

    if unresolved:
        rc = 1
        print(f"\nUNRESOLVED -- {len(unresolved)} symbol(s) imported by the stock "
              f"modules that neither our kernel nor any other stock module "
              f"provides:")
        for sym, mods in sorted(unresolved.items())[:40]:
            print(f"  {sym}  (wanted by {len(mods)}: {', '.join(mods[:3])}"
                  f"{'...' if len(mods) > 3 else ''})")
        if len(unresolved) > 40:
            print(f"  ... and {len(unresolved) - 40} more")

    if mismatched:
        rc = 1
        print(f"\nCRC MISMATCH -- {len(mismatched)} symbol(s). These break module "
              f"loading. Almost certainly a KMI type change:")
        for sym, (want, have, mods) in sorted(mismatched.items())[:40]:
            print(f"  {sym}\n      stock expects 0x{want:08x}, we export 0x{have:08x}"
                  f"  (affects {len(mods)} module(s))")
        if len(mismatched) > 40:
            print(f"  ... and {len(mismatched) - 40} more")

    # A CRC mismatch is fatal and always ours to fix. An unresolved symbol is
    # usually just a module set we were not given: vendor_dlkm.img and
    # system_dlkm.img hold modules too, and they are EROFS images this script
    # is not asked to open. So the two cases get different verdicts.
    if mismatched:
        print("\nDO NOT FLASH: CRC mismatch means the KMI diverged.")
        print("    Rebuild with CONFIG_SCHED_BORE=n and re-run -- if the")
        print("    mismatches disappear, the BORE port moved a KMI type.")
        return 1

    print("\nOK: no CRC mismatches. Every symbol the stock modules import that")
    print(f"    this kernel provides ({len(checked_syms) - len(missing)} of "
          f"{len(checked_syms)}) matches exactly, so the frozen KMI is intact.")
    if unresolved:
        print(f"\nNOT OUR PROBLEM: {len(unresolved)} symbol(s) that no module in the")
        print("    set provides either. If you passed every module image the device")
        print("    ships (vendor_boot's ramdisk, vendor_dlkm, system_dlkm), then the")
        print("    stock kernel cannot resolve these either and the importing module")
        print("    fails to load there too -- a firmware quirk, not an ABI problem.")
        print("    If you left an image out, extract it and pass its directory too.")
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
