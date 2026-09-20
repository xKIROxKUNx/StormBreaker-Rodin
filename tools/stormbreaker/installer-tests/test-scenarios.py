import os, shutil, struct, subprocess, sys, pathlib
S = pathlib.Path(sys.argv[1]); SRC = pathlib.Path(sys.argv[2])
INST = SRC/'installer'
stock = (SRC/'dist/boot-stock.img').read_bytes(); PART = len(stock)
vboff, vbsz = struct.unpack('>QQ', stock[-64:][20:36])
NEWSZ = 18030592

def sandbox(name):
    d = S/'sb'/name
    shutil.rmtree(d, ignore_errors=True); d.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(INST, d, ignore=shutil.ignore_patterns('Image', 'Image.lz4', 'Image.gz'))
    (d/'Image').write_bytes(b'MZ@\xfa' + b'\0'*1020)            # payload placeholder
    for s in (S/'stubs').iterdir():
        shutil.copy2(s, d/'tools'/s.name); os.chmod(d/'tools'/s.name, 0o755)
    (d/'blockdir').mkdir()
    (d/'blockdir'/'boot_b').write_bytes(stock)                 # the simulated partition
    # The repack stub returns this verbatim, so it has to look like a real boot
    # image: header page from the stock dump, kernel carrying the same
    # compression magic, so the engine's format check sees a faithful repack.
    hdr = bytearray(stock[:4096])
    struct.pack_into('<I', hdr, 8, NEWSZ - 4096)               # kernel_size
    struct.pack_into('<I', hdr, 12, 0)                         # ramdisk_size
    (d/'newimg').write_bytes(bytes(hdr) + b'\x02\x21\x4c\x18' + os.urandom(NEWSZ - 4100))
    cfg = (d/'config.sh').read_text().replace(
        'BLOCK_SEARCH_PATHS="/dev/block/mapper', f'BLOCK_SEARCH_PATHS="{d}/blockdir /dev/block/mapper')
    (d/'config.sh').write_text(cfg)
    return d

def props(d, device):
    (d/'props').write_text(f"ro.product.device={device}\nro.boot.slot_suffix=_b\n")
    return d/'props'

def run(d, kmi, device, temp_root=None):
    env = dict(os.environ, SB_PROPS=str(props(d, device)), SB_UNAME_R=f"6.6.30-{kmi}-gabc123",
               SB_NEWIMG=str(d/'newimg'), OUTFD="1")
    if temp_root: env['SB_TEMP_ROOT'] = str(temp_root)
    r = subprocess.run(['sh', './flasher.sh'], cwd=d, env=env, capture_output=True, text=True)
    return r, (d/'blockdir'/'boot_b').read_bytes()

def avb_ok(blk, newsz):
    if len(blk) != PART: return f"partition size changed: {len(blk)}"
    ft = blk[-64:]
    if ft[:4] != b'AVBf': return "sem AVBf no fim"
    o, vo, vs = struct.unpack('>QQQ', ft[12:36])
    if (o, vo, vs) != (newsz, newsz, vbsz): return f"footer {o}/{vo}/{vs} != {newsz}/{newsz}/{vbsz}"
    if blk[vo:vo+4] != b'AVB0': return f"sem AVB0 em {vo}"
    if blk[vo:vo+vbsz] != stock[vboff:vboff+vbsz]: return "blob is not the device's own"
    return None

def show(r, keys):
    for l in r.stdout.splitlines():
        t = l.replace('ui_print', '', 1).strip()
        if t and any(k in t for k in keys): print("     ", t)

ok = []

# ---------------------------------------------------------------- cenario 1
print("=== 1. Unknown codename (KMI compatible) ===")
d = sandbox('name'); r, blk = run(d, "android15-8", "xiaomi_othermodel")
show(r, ['Device', 'not in this', 'Continuing', 'KMI', 'Page size', 'compatible', 'AVB chain', 'Readback'])
bad = avb_ok(blk, NEWSZ)
c1 = (r.returncode == 0 and bad is None and "not in this kernel's tested device list" in r.stdout)
print("     ->", "PASS: warned and installed" if c1 else f"FAIL rc={r.returncode} {bad}"); ok.append(c1)

# ---------------------------------------------------------------- cenario 2
print("\n=== 2. Incompatible KMI ===")
tmproot = S/'sb'/'stormbreaker_installer'; shutil.rmtree(tmproot, ignore_errors=True)
tmproot.mkdir(parents=True); (tmproot/'junk').write_bytes(b'x'*4096)
d = sandbox('kmi'); r, blk = run(d, "android14-11", "rodin", temp_root=tmproot)
show(r, ['Device', 'KMI', 'vendor module', 'Incompatible', 'aborted'])
leftovers = [f.name for f in d.iterdir() if f.name in
             ('boot.img','boot-new.img','kernel','.expected','.vbmeta','.avbf')]
c2 = (r.returncode == 1 and blk == stock and not leftovers and not tmproot.exists())
print("     -> partition untouched:", blk == stock, "| temp files left:", leftovers or "none",
      "| SB_TEMP_ROOT removed:", not tmproot.exists())
print("     ->", "PASS: aborted and cleaned up" if c2 else f"FAIL rc={r.returncode}"); ok.append(c2)

# ---------------------------------------------------------------- cenario 3
print("\n=== 3. Engine alone, with broken modules ===")
d = sandbox('broken')
(d/'modules'/'ui.sh').write_text("#!/bin/sh\nui_print() { if [ ; then\n")      # invalid syntax
(d/'modules'/'post-flash.sh').write_text("#!/bin/sh\ncase x in\n")            # invalid syntax
(d/'modules'/'devices.sh').unlink()                                           # missing
(d/'modules'/'before-flash.sh').unlink()                                      # missing
(d/'extras'/'99-bad.sh').write_text("#!/bin/sh\nfor x in; do\n")              # broken add-on
r, blk = run(d, "android15-8", "rodin")
show(r, ['syntax error', 'Kernel payload', 'AVB chain', 'written to', 'Add-on'])
bad = avb_ok(blk, NEWSZ)
c3 = (r.returncode == 0 and bad is None
      and r.stdout.count('has a syntax error and was skipped') == 3)
print("     ->", "PASS: skipped the 3 broken ones and installed" if c3 else f"FAIL rc={r.returncode} {bad}")
ok.append(c3)

print("\n==>", "ALL PASSED" if all(ok) else "FAILURES")
sys.exit(0 if all(ok) else 1)
