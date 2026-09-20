"""The hardware lesson: pre-flight said writable, the real write failed.

The probe had rehearsed a different dd invocation than the one the engine went
on to use, so it could not have caught the difference. These tests pin that
down: every write to the partition must use the same flags the probe used, and
a dd that cannot write must be caught in pre-flight -- before the dump.
"""
import os, shutil, struct, subprocess, sys, pathlib
S = pathlib.Path(sys.argv[1]); SRC = pathlib.Path(sys.argv[2])
INST = SRC/'installer'
stock = (SRC/'dist/boot-stock.img').read_bytes(); PART = len(stock)
NEWSZ = 18030592

def sandbox(name, dd_stub):
    d = S/'ddp'/name
    shutil.rmtree(d, ignore_errors=True); d.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(INST, d, ignore=shutil.ignore_patterns('Image', 'Image.lz4', 'Image.gz'))
    (d/'Image').write_bytes(b'MZ@\xfa' + b'\0'*1020)
    for s in (S/'stubs').iterdir():
        if s.name.startswith('dd-') or s.name in ('magiskboot-fmt',): continue
        shutil.copy2(s, d/'tools'/s.name); os.chmod(d/'tools'/s.name, 0o755)
    shutil.copy2(S/'stubs'/dd_stub, d/'tools'/'dd'); os.chmod(d/'tools'/'dd', 0o755)
    (d/'blockdir').mkdir(); (d/'blockdir'/'boot_b').write_bytes(stock)
    hdr = bytearray(stock[:4096])
    struct.pack_into('<I', hdr, 8, NEWSZ - 4096); struct.pack_into('<I', hdr, 12, 0)
    (d/'newimg').write_bytes(bytes(hdr) + b'\x02\x21\x4c\x18' + os.urandom(NEWSZ - 4100))
    cfg = (d/'config.sh').read_text().replace(
        'BLOCK_SEARCH_PATHS="/dev/block/mapper', f'BLOCK_SEARCH_PATHS="{d}/blockdir /dev/block/mapper')
    (d/'config.sh').write_text(cfg)
    (d/'props').write_text("ro.product.device=rodin\nro.boot.slot_suffix=_b\nsys.boot_completed=1\n")
    return d

def run(d, ddlog=None):
    env = dict(os.environ, SB_PROPS=str(d/'props'), SB_UNAME_R="6.6.30-android15-8-gabc",
               SB_NEWIMG=str(d/'newimg'), OUTFD="1")
    if ddlog: env['SB_DDLOG'] = str(ddlog)
    return subprocess.run(['sh', './flasher.sh'], cwd=d, env=env, capture_output=True, text=True)

ok = []

# --- 1. every write to the partition uses the same invocation form -----------
print("=== 1. Probe and real write use the same invocation ===")
d = sandbox('parity', 'dd'); log = d/'ddlog'
r = run(d, log)
# Writes only: the target has to be the block, not merely mentioned as the
# source of a read.
def target(line):
    return next((a.split('=', 1)[1] for a in line.split() if a.startswith('of=')), '')
writes = [l for l in log.read_text().splitlines() if target(l).endswith('blockdir/boot_b')]
def convs(line):
    return next((a.split('=',1)[1] for a in line.split() if a.startswith('conv=')), '<none>')
forms = [convs(w) for w in writes]
for w in writes:
    print("      ", " ".join(a for a in w.split() if not a.startswith('if=')))
c1 = r.returncode == 0 and len(writes) >= 3 and len(set(forms)) == 1 and forms[0] == 'notrunc'
print(f"      conv forms used: {sorted(set(forms))}")
print("     ->", "PASS: probe and writes share one form" if c1 else f"FAIL rc={r.returncode}")
ok.append(c1)

# --- 2. a dd that cannot write is caught before the dump ---------------------
print("\n=== 2. a dd that cannot write ===")
d = sandbox('refuse', 'dd-refuse-write')
r = run(d)
blk = (d/'blockdir'/'boot_b').read_bytes()
dumped = (d/'boot.img').exists()
# The reason has to survive to the user: either dd's own words, or the name
# for a partition that takes the write and drops it.
reason = ('Operation not permitted' in r.stdout
          or 'accepted the write and dropped it' in r.stdout)
for l in r.stdout.splitlines():
    t = l.replace('ui_print','',1).strip()
    if t and ('cannot be written' in t or 'aborted' in t or 'recovery' in t.lower()): print("      ", t)
c2 = r.returncode != 0 and blk == stock and not dumped and reason
print("      partition untouched:", blk == stock, "| got as far as dumping:", dumped,
      "| reason in the log:", reason)
print("     ->", "PASS: stopped in pre-flight, with the reason" if c2 else f"FAIL rc={r.returncode}")
ok.append(c2)

# --- 3. a partition that takes the write and drops it ------------------------
print("\n=== 3. write accepted and dropped (UFS write-protected) ===")
d = sandbox('silent', 'dd-silent-drop')
r = run(d)
blk = (d/'blockdir'/'boot_b').read_bytes()
dumped = (d/'boot.img').exists()
named = 'accepted the write and dropped it' in r.stdout
for l in r.stdout.splitlines():
    t = l.strip()
    if 'dropped it' in t or 'write-protected' in t or 'recovery' in t.lower(): print("      ", t)
c3 = r.returncode != 0 and blk == stock and not dumped and named
print("      partition untouched:", blk == stock, "| got as far as dumping:", dumped,
      "| named the cause:", named)
print("     ->", "PASS: probe caught the silent drop" if c3 else f"FAIL rc={r.returncode}")
ok.append(c3)

print("\n==>", "ALL PASSED" if all(ok) else "FAILURES")
sys.exit(0 if all(ok) else 1)
