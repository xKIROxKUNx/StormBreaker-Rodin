import os, shutil, struct, subprocess, sys, pathlib
S = pathlib.Path(sys.argv[1]); SRC = pathlib.Path(sys.argv[2])
STOCK = SRC/'dist/boot-stock.img'
stock = STOCK.read_bytes()
PART = len(stock)
f = stock[-64:]
orig, vboff, vbsz = struct.unpack('>QQQ', f[12:36])
print(f"stock: part={PART} image={orig} vbmeta_offset={vboff} vbmeta_size={vbsz}\n")

def mkimg(size, tail=False):
    """Fake repacked image. tail=True mimics magiskboot appending AVB0+AVBf."""
    body = bytearray(b'ANDROID!' + os.urandom(size-8))
    if not tail: return bytes(body)
    blob = stock[vboff:vboff+vbsz]
    ft = bytearray(f); ft[12:20] = struct.pack('>Q', size); ft[20:28] = struct.pack('>Q', size)
    return bytes(body) + blob + b'\0'*(4096-vbsz%4096) + bytes(ft)

def run(name, newsize, tail=False, expect_ok=True):
    work = S/'w'; shutil.rmtree(work, ignore_errors=True); work.mkdir(parents=True)
    (work/'fakeblock').write_bytes(stock)          # the live partition
    (work/'boot.img').write_bytes(stock)           # the dump the engine takes
    (work/'boot-new.img').write_bytes(mkimg(newsize, tail))
    env = dict(os.environ, WORK=str(work), CORE=str(S/'avb-core.sh'))
    r = subprocess.run(['sh', str(S/'harness.sh')], env=env,
                       capture_output=True, text=True)
    print(f"--- {name}")
    print(r.stdout.rstrip())
    if r.stderr.strip(): print("stderr:", r.stderr.strip()[:400])

    d = (work/'fakeblock').read_bytes()
    ok = True
    if len(d) != PART: print(f"   FAIL: partition size changed -> {len(d)}"); ok = False
    if expect_ok:
        ft = d[-64:]
        if ft[:4] != b'AVBf': print("   FAIL: no AVBf at partition end"); ok = False
        else:
            o2, vo2, vs2 = struct.unpack('>QQQ', ft[12:36])
            if vo2 != newsize or o2 != newsize:
                print(f"   FAIL: footer says image={o2} offset={vo2}, expected {newsize}"); ok = False
            elif d[vo2:vo2+4] != b'AVB0':
                print(f"   FAIL: no AVB0 at {vo2}"); ok = False
            elif d[vo2:vo2+vbsz] != stock[vboff:vboff+vbsz]:
                print("   FAIL: vbmeta blob is not the device's own stock blob"); ok = False
            elif vs2 != vbsz:
                print(f"   FAIL: vbmeta_size changed {vbsz}->{vs2}"); ok = False
            elif d[:newsize] != (work/'boot-new.img').read_bytes()[:newsize]:
                print("   FAIL: payload bytes on partition differ"); ok = False
            else:
                print(f"   PASS: image={o2} offset={vo2} blob identical to stock, footer at {PART-64}")
    else:
        if r.returncode != 7: print(f"   FAIL: expected refusal, got rc={r.returncode}"); ok = False
        elif d != stock: print("   FAIL: partition modified despite refusal"); ok = False
        else: print("   PASS: refused and left the partition untouched")
    return ok

results = []
results.append(run("A: LARGER kernel (17190912 -> 18030592)", 18030592))
results.append(run("B: SMALLER kernel (17190912 -> 17000960)", 17000960))
results.append(run("C: magiskboot appended a tail (image 18116608 + AVB0 + AVBf)", 18116608, tail=True))
results.append(run("D: image fills the partition, no room for vbmeta", 67108864, expect_ok=False))
results.append(run("E: image larger than the partition", 70000640, expect_ok=False))
results.append(run("F: image fits exactly (part-64-vbmeta, aligned)", 67104768))
print("\n==>", "ALL PASSED" if all(results) else "FAILURES")
sys.exit(0 if all(results) else 1)
