"""Mutation test for the footer encoder guard.

Android's mksh computes in 32 bits and takes shift counts modulo 32, so
"$(( n >> 56 ))" quietly returns "$(( n >> 24 ))". Measured on a rodin, that
made be64_write emit the low four bytes twice, and be64_read -- sharing the
same arithmetic -- decode them back to the right number, so the engine's own
readback approved a footer libavb would have rejected.

No 32-bit shell here to reproduce it, so the bug is injected instead: replace
the encoder with the one that shell effectively produced, and require the guard
to refuse the write and put the partition back.
"""
import os, shutil, struct, subprocess, sys, pathlib
S = pathlib.Path(sys.argv[1]); SRC = pathlib.Path(sys.argv[2])
stock = (SRC/'dist/boot-stock.img').read_bytes(); PART = len(stock)
NEWSZ = 18030592

BUGGY = '''be64_write() {  # the encoding a 32-bit shell actually produced
    _n="$1"; _esc=""; _i=3
    while [ "$_i" -ge 0 ]; do
        _esc="$_esc\\\\0$(printf '%03o' $(( (_n >> (_i * 8)) & 255 )))"
        _i=$(( _i - 1 ))
    done
    printf '%b%b' "$_esc" "$_esc"
}
'''

def core_with(mutation):
    src = (S/'avb-core.sh').read_text()
    start = src.index('be64_write() {')
    end = src.index('\n}\n', start) + 3
    return src[:start] + mutation + src[end:]

def run(core_text, name):
    work = S/'guard'/name
    shutil.rmtree(work, ignore_errors=True); work.mkdir(parents=True)
    (work/'fakeblock').write_bytes(stock)
    (work/'boot.img').write_bytes(stock)
    (work/'boot-new.img').write_bytes(b'ANDROID!' + os.urandom(NEWSZ-8))
    core = S/'guard'/f'{name}-core.sh'; core.write_text(core_text)
    env = dict(os.environ, WORK=str(work), CORE=str(core))
    r = subprocess.run(['sh', str(S/'harness.sh')], env=env, capture_output=True, text=True)
    return r, (work/'fakeblock').read_bytes()

ok = []

print("=== 1. Correct encoder: installs ===")
r, blk = run((S/'avb-core.sh').read_text(), 'good')
ft = blk[-64:]; o, vo, vs = struct.unpack('>QQQ', ft[12:36])
c1 = r.returncode == 0 and o == NEWSZ and vo == NEWSZ
print(f"      footer: image={o} vbmeta@{vo} size={vs}")
print("     ->", "PASS" if c1 else f"FAIL rc={r.returncode}"); ok.append(c1)

print("\n=== 2. 32-bit encoder injected: the guard must refuse ===")
r, blk = run(core_with(BUGGY), 'buggy')
for l in r.stdout.splitlines():
    t = l.strip()
    if 'encoded wrong' in t or 'expected' in t or 'got ' in t or 'Refusing' in t or 'restored' in t:
        print("      ", t)
c2 = (r.returncode == 7 and blk == stock and 'encoded wrong' in r.stdout)
print("      partition back to its original state:", blk == stock)
print("     ->", "PASS: refused and rolled back" if c2 else f"FAIL rc={r.returncode}"); ok.append(c2)

print("\n==>", "ALL PASSED" if all(ok) else "FAILURES")
sys.exit(0 if all(ok) else 1)
