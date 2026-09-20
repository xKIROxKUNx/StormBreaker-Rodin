import os, shutil, struct, subprocess, sys, pathlib
S = pathlib.Path(sys.argv[1]); SRC = pathlib.Path(sys.argv[2])
stock = (SRC/'dist/boot-stock.img').read_bytes(); PART = len(stock)
vboff, vbsz = struct.unpack('>QQ', stock[-64:][20:36])

def setup(blockdata):
    work = S/'w2'; shutil.rmtree(work, ignore_errors=True); work.mkdir(parents=True)
    (work/'fakeblock').write_bytes(blockdata)
    (work/'boot.img').write_bytes(blockdata)
    (work/'boot-new.img').write_bytes(b'ANDROID!' + os.urandom(18030592-8))
    return work

def run(work, extra=""):
    h = S/'harness2.sh'
    h.write_text((S/'harness.sh').read_text() + extra)
    env = dict(os.environ, WORK=str(work), CORE=str(S/'avb-core.sh'))
    return subprocess.run(['sh', str(h)], env=env, capture_output=True, text=True)

ok = []
# G: device whose boot partition carries no AVB footer at all
d = bytearray(stock); d[-64:] = b'\0'*64
w = setup(bytes(d)); r = run(w)
out = r.stdout
g = ("No AVB footer" in out and r.returncode == 0
     and len((w/'fakeblock').read_bytes()) == PART
     and (w/'fakeblock').read_bytes()[:18030592] == (w/'boot-new.img').read_bytes())
print("--- G: partition with no AVB footer");  print("   ", [l.strip() for l in out.splitlines() if 'footer' in l or 'ok ' in l])
print("   ", "PASS: wrote normally, invented no footer" if g else "FAIL"); ok.append(g)

# H: footer present but the blob it points at is gone
d = bytearray(stock); d[vboff:vboff+4] = b'\0\0\0\0'
w = setup(bytes(d)); r = run(w)
h_ok = ("not found where it points" in r.stdout and r.returncode == 0
        and len((w/'fakeblock').read_bytes()) == PART)
print("--- H: footer points at a blob that is not there")
print("   ", [l.strip() for l in r.stdout.splitlines() if 'WARN' in l or '!!' in l])
print("   ", "PASS: warned and fabricated no chain" if h_ok else "FAIL"); ok.append(h_ok)

# I: rollback restores the partition byte for byte
w = setup(stock)
r = run(w, '\navb_restore_and_die "simulated failure"\n')
back = (w/'fakeblock').read_bytes()
i_ok = (r.returncode == 7 and back == stock)
print("--- I: rollback after a failure")
print("   ", [l.strip() for l in r.stdout.splitlines() if 'Restor' in l or 'restored' in l])
print("   ", "PASS: partition restored byte for byte" if i_ok else "FAIL"); ok.append(i_ok)

print("\n==>", "ALL PASSED" if all(ok) else "FAILURES")
sys.exit(0 if all(ok) else 1)
