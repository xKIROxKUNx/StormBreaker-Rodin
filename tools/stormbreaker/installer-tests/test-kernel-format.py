"""Does the kernel going in keep the compression format the device boots?

Scenario 1: a device whose boot image carries an lz4_legacy kernel (the real
            stock dump from the rodin).
Scenario 2: a device whose boot image carries a gzip kernel.
Scenario 3: the same gzip device, but the package ships a pre-compressed
            Image.lz4 -- the old behaviour, which must now be refused.
"""
import gzip, os, shutil, struct, subprocess, sys, pathlib
S = pathlib.Path(sys.argv[1]); SRC = pathlib.Path(sys.argv[2])
INST = SRC/'installer'
stock = (SRC/'dist/boot-stock.img').read_bytes(); PART = len(stock)
vboff, vbsz = struct.unpack('>QQ', stock[-64:][20:36])
BLOB = stock[vboff:vboff+vbsz]
FOOTER = stock[-64:]
RAW_IMAGE = b'MZ@\xfa' + os.urandom(4*1024*1024 - 4)      # stands in for arch/arm64/boot/Image

def build_partition(kernel_blob):
    """A 64 MiB boot partition whose kernel is kernel_blob, AVB tail intact."""
    hdr = bytearray(stock[:4096])
    struct.pack_into('<I', hdr, 8, len(kernel_blob))       # kernel_size
    struct.pack_into('<I', hdr, 12, 0)                     # ramdisk_size
    img = bytes(hdr) + kernel_blob
    img += b'\0' * ((len(img) + 4095) // 4096 * 4096 - len(img))
    off = len(img)
    ft = bytearray(FOOTER)
    ft[12:20] = struct.pack('>Q', off); ft[20:28] = struct.pack('>Q', off)
    out = img + BLOB + b'\0' * (PART - 64 - off - len(BLOB)) + bytes(ft)
    assert len(out) == PART
    return out

def sandbox(name, partition, payload_name, payload):
    d = S/'fmt'/name
    shutil.rmtree(d, ignore_errors=True); d.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(INST, d, ignore=shutil.ignore_patterns('Image', 'Image.lz4', 'Image.gz'))
    (d/payload_name).write_bytes(payload)
    for s in (S/'stubs').iterdir():
        if s.name == 'magiskboot-fmt': continue
        shutil.copy2(s, d/'tools'/s.name); os.chmod(d/'tools'/s.name, 0o755)
    shutil.copy2(S/'stubs'/'magiskboot-fmt', d/'tools'/'magiskboot')
    os.chmod(d/'tools'/'magiskboot', 0o755)
    (d/'blockdir').mkdir(); (d/'blockdir'/'boot_b').write_bytes(partition)
    cfg = (d/'config.sh').read_text().replace(
        'BLOCK_SEARCH_PATHS="/dev/block/mapper', f'BLOCK_SEARCH_PATHS="{d}/blockdir /dev/block/mapper')
    (d/'config.sh').write_text(cfg)
    (d/'props').write_text("ro.product.device=rodin\nro.boot.slot_suffix=_b\n")
    return d

def run(d):
    env = dict(os.environ, SB_PROPS=str(d/'props'), SB_UNAME_R="6.6.30-android15-8-gabc",
               OUTFD="1")
    r = subprocess.run(['sh', './flasher.sh'], cwd=d, env=env, capture_output=True, text=True)
    return r, (d/'blockdir'/'boot_b').read_bytes()

def kernel_magic(blk):
    ksz = struct.unpack_from('<I', blk, 8)[0]
    return blk[4096:4100].hex(), ksz

def show(r, keys):
    for l in r.stdout.splitlines():
        t = l.replace('ui_print', '', 1).strip()
        if t and any(k in t for k in keys): print("     ", t)

ok = []
LZ4, GZ = '02214c18', '1f8b'

# ---------------------------------------------------------------- 1. lz4
print("=== 1. lz4_legacy device (real rodin dump) + raw Image ===")
before = kernel_magic(stock)
d = sandbox('lz4', stock, 'Image', RAW_IMAGE)
r, blk = run(d)
show(r, ['kernel format', 'format preserved', 'AVB chain', 'Readback'])
after, ksz = kernel_magic(blk)
c1 = r.returncode == 0 and after == LZ4 and ksz != before[1]
print(f"      before {before[0]} -> after {after}  (kernel_size {before[1]} -> {ksz})")
print("     ->", "PASS: recompressed as lz4_legacy" if c1 else f"FAIL rc={r.returncode}"); ok.append(c1)

# ---------------------------------------------------------------- 2. gzip
print("\n=== 2. gzip device + raw Image ===")
gz_part = build_partition(gzip.compress(os.urandom(3*1024*1024), 9, mtime=0))
before = kernel_magic(gz_part)
d = sandbox('gzip', gz_part, 'Image', RAW_IMAGE)
r, blk = run(d)
show(r, ['kernel format', 'format preserved', 'AVB chain', 'Readback'])
after, ksz = kernel_magic(blk)
c2 = r.returncode == 0 and after.startswith(GZ) and ksz != before[1]
print(f"      before {before[0]} -> after {after}  (kernel_size {before[1]} -> {ksz})")
print("     ->", "PASS: recompressed as gzip" if c2 else f"FAIL rc={r.returncode}"); ok.append(c2)

# ---------------------------------------------------------------- 3. controle
print("\n=== 3. Control: gzip device + pre-compressed Image.lz4 ===")
lz4_payload = subprocess.run(['lz4', '-9', '-f', '-l', '-c'], input=RAW_IMAGE,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             check=True).stdout
d = sandbox('control', gz_part, 'Image.lz4', lz4_payload)
r, blk = run(d)
show(r, ['kernel format', 'different format', 'starts with', 'Kernel format mismatch'])
c3 = r.returncode == 1 and blk == gz_part
print("      partition untouched:", blk == gz_part)
print("     ->", "PASS: refused before writing" if c3 else f"FAIL rc={r.returncode}"); ok.append(c3)

print("\n==>", "ALL PASSED" if all(ok) else "FAILURES")
sys.exit(0 if all(ok) else 1)
