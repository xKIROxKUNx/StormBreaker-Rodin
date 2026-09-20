#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""
Graft the stock boot partition's signed AVB vbmeta onto a freshly built boot.img.

Why
---
On this device (POCO rodin, MT6899) `vbmeta` covers the partitions two different
ways:

    CHAIN  boot                 <- authority lives INSIDE the partition
    CHAIN  vbmeta_system
    CHAIN  vbmeta_vendor
    HASH   dtbo
    HASH   init_boot
    HASH   vendor_boot          <- authority is the top-level vbmeta

For the HASH ones, a modified image just fails its digest check, which an
unlocked bootloader tolerates -- that is why a custom recovery (vendor_boot)
and a patched init_boot both boot while carrying an unsigned
`Algorithm: NONE` footer.

`boot` is the only CHAIN partition, and it is the only one where no host-built
image has ever booted on this device -- not ours, and not the pre-built images
published by other projects either. That pattern is the clue: a host cannot produce a
vbmeta signed with the ROM's key, so a host-built boot.img either has no vbmeta
at all (chain cannot be resolved -> AVB_SLOT_VERIFY_RESULT_ERROR_INVALID_METADATA,
which libavb treats as fatal even when verification errors are allowed) or an
unsigned one (public key does not match the chain descriptor).

AnyKernel3 does not have this problem because it never builds an image: it dumps
the live partition, swaps the kernel bytes and writes it back, so the stock
signed vbmeta rides along untouched.

This script does the same thing for the fastboot path. It keeps the stock vbmeta
blob byte-for-byte -- signature intact, key intact, rollback index intact -- and
only moves it to sit after the new, larger boot image. The hash descriptor inside
it still describes the old kernel, so verification ends in HASH_MISMATCH, which
libavb reports as a verification *error* rather than a metadata error and which
an unlocked bootloader is documented to allow (orange state).

Layout produced (partition size taken from the stock footer):

    0                     .. len(new boot image)    new boot image
    len(new boot image)   .. + vbmeta_size          stock vbmeta blob, verbatim
    ...                                             zero padding
    partition_size - 64   .. partition_size         new AvbFooter

Usage
-----
    graft-avb-footer.py <new-boot.img> <stock-boot.img> <output.img>

Exit status: 0 on success, 1 on any inconsistency.
"""

import os
import struct
import sys

FOOTER_MAGIC = b"AVBf"
FOOTER_SIZE = 64
VBMETA_MAGIC = b"AVB0"


def read_footer(data):
    """Parse the AvbFooter in the last 64 bytes. All fields are big-endian."""
    if len(data) < FOOTER_SIZE:
        return None
    f = data[-FOOTER_SIZE:]
    if f[:4] != FOOTER_MAGIC:
        return None
    ver_major, ver_minor = struct.unpack_from(">II", f, 4)
    original_image_size, vbmeta_offset, vbmeta_size = struct.unpack_from(">QQQ", f, 12)
    return {
        "ver_major": ver_major,
        "ver_minor": ver_minor,
        "original_image_size": original_image_size,
        "vbmeta_offset": vbmeta_offset,
        "vbmeta_size": vbmeta_size,
    }


def build_footer(original_image_size, vbmeta_offset, vbmeta_size, ver=(1, 0)):
    f = bytearray(FOOTER_SIZE)
    f[0:4] = FOOTER_MAGIC
    struct.pack_into(">II", f, 4, ver[0], ver[1])
    struct.pack_into(">QQQ", f, 12, original_image_size, vbmeta_offset, vbmeta_size)
    # the remaining 28 bytes stay zero (AvbFooter.reserved)
    return bytes(f)


def main(argv):
    if len(argv) != 4:
        print(__doc__)
        return 1
    new_path, stock_path, out_path = argv[1], argv[2], argv[3]

    for p in (new_path, stock_path):
        if not os.path.isfile(p):
            print(f"not a file: {p}", file=sys.stderr)
            return 1

    stock = open(stock_path, "rb").read()
    partition_size = len(stock)

    footer = read_footer(stock)
    if not footer:
        print(f"{stock_path}: no AVB footer in the last {FOOTER_SIZE} bytes.",
              file=sys.stderr)
        print("Without the stock vbmeta there is nothing to graft.", file=sys.stderr)
        return 1

    voff = footer["vbmeta_offset"]
    vsz = footer["vbmeta_size"]
    blob = stock[voff:voff + vsz]
    if blob[:4] != VBMETA_MAGIC:
        print(f"{stock_path}: expected {VBMETA_MAGIC!r} at offset {voff}, "
              f"found {blob[:4]!r}.", file=sys.stderr)
        return 1

    new = open(new_path, "rb").read()
    new_size = len(new)

    # The vbmeta blob has to fit between the new image and the footer.
    needed = new_size + vsz + FOOTER_SIZE
    if needed > partition_size:
        print(f"does not fit: image {new_size} + vbmeta {vsz} + footer "
              f"{FOOTER_SIZE} = {needed} > partition {partition_size}.",
              file=sys.stderr)
        return 1

    out = bytearray(partition_size)
    out[0:new_size] = new
    out[new_size:new_size + vsz] = blob
    out[partition_size - FOOTER_SIZE:] = build_footer(new_size, new_size, vsz)

    with open(out_path, "wb") as fh:
        fh.write(out)

    print(f"partition size      : {partition_size}")
    print(f"new boot image      : {new_size} bytes")
    print(f"stock vbmeta blob   : {vsz} bytes, grafted at offset {new_size}")
    print(f"footer              : at {partition_size - FOOTER_SIZE}, "
          f"points to {new_size}")
    print(f"wrote               : {out_path}")

    # Read our own output back through the same parser as a sanity check.
    check = read_footer(open(out_path, "rb").read())
    if (not check
            or check["vbmeta_offset"] != new_size
            or check["vbmeta_size"] != vsz
            or check["original_image_size"] != new_size):
        print("self-check failed: the footer we just wrote does not parse back "
              "as expected.", file=sys.stderr)
        return 1
    print("self-check          : footer parses back correctly")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
