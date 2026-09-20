#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# Modular kernel flasher engine.
#
# Layout:
#   config.sh      everything project-specific -- the only file to edit to
#                  adapt this installer to another kernel
#   banner.txt     the art and hardware blurb, as data
#   modules/       lifecycle hooks: ui, devices, before-flash, post-flash
#   extras/        optional drop-in add-ons, run after a verified install
#
# The engine is self-sufficient: every module is optional and a broken one is
# skipped, so a package stripped down to flasher.sh + a kernel image still
# installs correctly.
#
# No `set -e`: aborts are explicit, so that each failure can say what it was and
# clean up after itself.

CWD="$(cd "$(dirname "$0")" && pwd)"
cd "$CWD" || exit 1

[ -d "$CWD/tools" ] && export PATH="$CWD/tools:$PATH"

# ==============================================================================
# 1. CONFIGURATION
# ==============================================================================
[ -f "$CWD/config.sh" ] && . "$CWD/config.sh"

# Defaults, so a package without config.sh still does the right thing.
KERNEL_NAME="${KERNEL_NAME:-kernel}"
KERNEL_STRING="${KERNEL_STRING:-$KERNEL_NAME}"
TARGET_PARTITION="${TARGET_PARTITION:-boot}"
BLOCK_SEARCH_PATHS="${BLOCK_SEARCH_PATHS:-/dev/block/mapper /dev/block/by-name /dev/block/bootdevice/by-name /dev/block/platform/*/by-name}"
KERNEL_PAYLOADS="${KERNEL_PAYLOADS:-Image.lz4 Image.gz Image}"

# ==============================================================================
# 2. FALLBACK UI (replaced by modules/ui.sh when present)
# ==============================================================================
OUTFD="${OUTFD:-${2:-1}}"

type ui_print >/dev/null 2>&1 || ui_print() {
    while [ $# -gt 0 ]; do
        if [ -n "$OUTFD" ] && [ -e "/proc/self/fd/$OUTFD" ]; then
            printf "ui_print %s\nui_print\n" "$1" >> "/proc/self/fd/$OUTFD" 2>/dev/null ||
                printf "ui_print %s\n" "$1"
        else
            printf "ui_print %s\n" "$1"
        fi
        shift
    done
}
type ui_msg     >/dev/null 2>&1 || ui_msg()     { ui_print "==> $1"; }
type ui_warn    >/dev/null 2>&1 || ui_warn()    { ui_print "!! [WARN] $1"; }
type ui_error   >/dev/null 2>&1 || ui_error()   { ui_print "XX [ERROR] $1"; }
type ui_success >/dev/null 2>&1 || ui_success() { ui_print " [OK] $1"; }
type ui_abort   >/dev/null 2>&1 || ui_abort()   { ui_error "$1"; sb_cleanup; exit 1; }

# ==============================================================================
# 3. ENVIRONMENT CLEANUP
# ==============================================================================
# Called on every exit path, including aborts. Installs run in tmpfs, where the
# dump plus the repacked image are a hundred megabytes that a recovery cannot
# spare -- and leaving a half-built image behind would also be read as a
# finished one by anything that looked later.
sb_cleanup() {
    rm -rf boot.img boot-new.img kernel ramdisk dtb split_img second extra recovery_dtbo \
           .expected .peek .peek4 .nfoot .nfo .avbf .avbo .avbs .avbf-new .vbmeta \
           .fh .ft .fo .chk .chko .dderr .wtest .hx 2>/dev/null

    # Only when the dispatcher had to extract the package itself: that tree is
    # ours to remove. Guarded so a stray value cannot turn this into an rm -rf
    # of something that matters.
    case "$SB_TEMP_ROOT" in
        /*stormbreaker_installer|/*stormbreaker_installer/*|"$AKHOME")
            [ -n "$SB_TEMP_ROOT" ] && [ -d "$SB_TEMP_ROOT" ] && {
                cd / 2>/dev/null
                rm -rf "$SB_TEMP_ROOT" 2>/dev/null
            }
            ;;
    esac
}

# ==============================================================================
# 3b. THE dd USED FOR EVERY PARTITION WRITE
# ==============================================================================
# Android ships toybox dd, recovery ships busybox dd, and they do not accept the
# same conv= flags. Writing the partition with a flag one of them rejects fails
# the whole install, so the package prefers the busybox it carries and every
# write goes through one invocation form, rehearsed in pre-flight.
#
# No conv=fsync anywhere: an explicit sync plus blockdev --flushbufs does the
# same job with flags both implementations accept. conv=notrunc is a no-op on a
# block device but says what is meant, and keeps seek= writes honest on a file.
DD="dd"
if [ -x "./tools/busybox" ] && ./tools/busybox dd if=/dev/null of=/dev/null count=0 2>/dev/null; then
    DD="$CWD/tools/busybox dd"
fi
DD_ERR=".dderr"

sb_dd() {   # dd arguments; on failure DD_ERR holds what it printed
    rm -f "$DD_ERR"
    $DD "$@" 2>"$DD_ERR"
}

dd_why() {  # last error, trimmed to one line for the recovery UI
    [ -s "$DD_ERR" ] || { printf 'no error output'; return; }
    tr '\n' ' ' < "$DD_ERR" | cut -c1-160
}

# ==============================================================================
# 4. MODULE LOADER
# ==============================================================================
# A module is optional and may come from someone adapting this package, so a
# syntax error in one must not take the engine down with it: in POSIX sh a
# parse error inside `.` aborts the whole shell, hence the check first.
load_module() {
    [ -f "$1" ] || return 1
    if ! sh -n "$1" 2>/dev/null; then
        ui_warn "Module $1 has a syntax error and was skipped."
        return 1
    fi
    . "$1"
}

# ==============================================================================
# 1b. AVB TAIL HELPERS
# ==============================================================================
# On this class of device the boot partition is an AVB *chain* partition: it
# ends with a 64-byte AVBf footer whose fields locate a signed vbmeta blob
# (AVB0) sitting right behind the boot image:
#
#   [ boot image ][ AVB0 blob ][ ... padding ... ][ AVBf footer ]
#   0             vbmeta_offset                    part_size-64
#
#   footer[12:20] = original_image_size   footer[20:28] = vbmeta_offset
#   footer[28:36] = vbmeta_size
#
# The bootloader reads the footer from the LAST 64 BYTES OF THE PARTITION, then
# follows vbmeta_offset to the blob. Both must come from the partition we are
# about to write -- that is, from THIS device's own stock. Never from a build
# host, and never from another device's image: the blob is signed with the ROM's
# private key, which is per-device-model.
#
# magiskboot does carry the tail across a repack, but where it lands once the
# kernel changes size is undocumented and nothing verifies it. So we take the
# footer and the blob out of the dump we already hold, place them ourselves at
# the offsets the new image dictates, and then check the result by reading the
# block back. If anything is off, we restore the dump.

# The AVB fields are 64-bit, and shell arithmetic is not. Android's mksh
# computes in 32 bits and takes shift counts modulo 32, so a naive
# "$(( n >> 56 ))" silently returns "$(( n >> 24 ))" -- which turns an 8-byte
# encode into the low four bytes written twice, and a matching decode that
# agrees with it. Measured on a rodin: the footer came out as
# 01136000 01136000 instead of 00000000 01136000, and the engine's own readback
# blessed it, because reader and writer shared the mistake.
#
# So nothing here shifts by 32 or more. The high word is handled as its own
# value, and anything that would not fit in it is refused rather than
# truncated.
be64_read() {   # <file holding exactly 8 bytes> -> decimal, or fails
    _hi=0; _lo=0; _n=0
    for _b in $(od -An -v -tu1 "$1" 2>/dev/null); do
        _n=$(( _n + 1 ))
        if [ "$_n" -le 4 ]; then _hi=$(( (_hi << 8) | _b ))
        else                     _lo=$(( (_lo << 8) | _b )); fi
    done
    [ "$_n" -eq 8 ] || return 1
    # A partition this arithmetic cannot describe is not one we should be
    # editing blind.
    [ "$_hi" -eq 0 ] && [ "$_lo" -ge 0 ] || return 1
    printf '%s' "$_lo"
}

be64_write() {  # <decimal, fits in 31 bits> -> 8 raw big-endian bytes
    _n="$1"; _esc='\0000\0000\0000\0000'; _i=3
    while [ "$_i" -ge 0 ]; do
        _esc="$_esc\\0$(printf '%03o' $(( (_n >> (_i * 8)) & 255 )))"
        _i=$(( _i - 1 ))
    done
    printf '%b' "$_esc"
}

hexn() {        # <file> <offset> <len> -> lowercase hex, no separators
    slice "$1" .hx "$2" "$3"
    od -An -v -tx1 .hx 2>/dev/null | tr -d ' \n'
    rm -f .hx
}

slice() {       # <src> <dst> <offset> <len>  -- small reads, byte granularity
    dd if="$1" of="$2" bs=1 skip="$3" count="$4" 2>/dev/null
}

# Magics are compared as hex, never as raw bytes: a command substitution eats
# NUL bytes (and warns, on some shells), so a non-matching magic could not be
# captured reliably as text.
AVBF_HEX=41564266   # "AVBf"
AVB0_HEX=41564230   # "AVB0"

le32_at() {     # <src> <offset> -> decimal on stdout
    _f="$1"; _o="$2"
    slice "$_f" .le4 "$_o" 4
    set -- $(od -An -v -tu1 .le4 2>/dev/null)
    rm -f .le4
    if [ $# -eq 4 ]; then
        printf '%s' $(( ($4 << 24) | ($3 << 16) | ($2 << 8) | $1 ))
    else
        printf '0'
    fi
}

# First four bytes of the kernel inside an Android boot image. That is its
# compression magic: 02214c18 lz4_legacy, 1f8b.... gzip, 4d5a.... a raw arm64
# Image. The bootloader only knows how to unpack the format the OEM shipped, so
# the kernel going in has to carry the same magic as the one coming out.
kernel_magic() {    # <boot image> -> 8 hex chars
    _img="$1"
    _hv=$(le32_at "$_img" 40)
    case "$_hv" in
        3|4) _ps=4096 ;;
        *)   _ps=$(le32_at "$_img" 36) ;;
    esac
    case "$_ps" in ''|0|*[!0-9]*) _ps=2048 ;; esac
    hex4_at "$_img" "$_ps"
}

hex4_at() {     # <src> <512-aligned offset> -> 8 hex chars on stdout
    dd if="$1" of=.peek bs=512 skip=$(( $2 / 512 )) count=1 2>/dev/null || return 1
    slice .peek .peek4 0 4
    od -An -v -tx1 .peek4 2>/dev/null | tr -d ' \n'
    rm -f .peek .peek4
}

# ==============================================================================
# 5. LIFECYCLE: UI, BANNER, COMPATIBILITY, PRE-FLIGHT
# ==============================================================================
load_module "modules/ui.sh"
type show_banner >/dev/null 2>&1 && show_banner

load_module "modules/devices.sh"
load_module "modules/before-flash.sh"

# Fallback block resolution when before-flash.sh is absent or was skipped.
if [ -z "$BOOT_BLOCK" ] || [ ! -e "$BOOT_BLOCK" ]; then
    SLOT="${SLOT:-$(getprop ro.boot.slot_suffix 2>/dev/null)}"
    [ -z "$SLOT" ] && SLOT=$(grep -o 'androidboot.slot_suffix=[^ ]*' /proc/cmdline 2>/dev/null | cut -d= -f2)
    for p in $BLOCK_SEARCH_PATHS; do
        if [ -e "$p/$TARGET_PARTITION$SLOT" ]; then
            BOOT_BLOCK="$p/$TARGET_PARTITION$SLOT"; break
        elif [ -e "$p/$TARGET_PARTITION" ]; then
            BOOT_BLOCK="$p/$TARGET_PARTITION"; break
        fi
    done
fi
[ -n "$BOOT_BLOCK" ] && [ -e "$BOOT_BLOCK" ] ||
    ui_abort "Could not locate the $TARGET_PARTITION partition."

# ==============================================================================
# 6. CORE: DUMP, SWAP KERNEL, REPACK, WRITE, VERIFY
# ==============================================================================
ui_msg "Starting installation engine..."

# 6.1 magiskboot
MAGISKBOOT=""
for mb in "./tools/magiskboot" "/sbin/magiskboot" "/system/bin/magiskboot" "/data/adb/magisk/magiskboot"; do
    if [ -x "$mb" ] || [ -f "$mb" ]; then
        chmod +x "$mb" 2>/dev/null || true
        MAGISKBOOT="$mb"; break
    fi
done
[ -n "$MAGISKBOOT" ] || ui_abort "magiskboot not found; cannot repack an AVB-signed image."

# 6.2 Kernel payload
KERNEL_PAYLOAD=""
for k in $KERNEL_PAYLOADS; do
    [ -f "$k" ] && { KERNEL_PAYLOAD="$k"; break; }
done
[ -n "$KERNEL_PAYLOAD" ] || ui_abort "No kernel image ($KERNEL_PAYLOADS) in this package."
ui_print "  Kernel payload: $KERNEL_PAYLOAD ($(wc -c < "$KERNEL_PAYLOAD" 2>/dev/null) bytes)"

# 6.3 Dump the live partition -- the repack template and the rollback copy
ui_msg "Dumping $BOOT_BLOCK..."
rm -rf boot.img boot-new.img ramdisk kernel split_img 2>/dev/null
dd if="$BOOT_BLOCK" of=boot.img bs=4096 2>/dev/null ||
    ui_abort "Failed to read $BOOT_BLOCK"

# 6.4 Unpack, swap, repack. Working from the device's own image is what keeps
#     its header fields, cmdline and security patch level intact.
ui_msg "Unpacking the live image..."
_unpack_log="$($MAGISKBOOT unpack boot.img 2>&1)" || ui_abort "magiskboot unpack failed"
_fmt=$(printf '%s' "$_unpack_log" | sed -n 's/.*KERNEL_FMT *\[\([^]]*\)\].*/\1/p' | head -n1)
[ -n "$_fmt" ] && ui_print "  Device kernel format: $_fmt"

ui_msg "Injecting the $KERNEL_NAME kernel..."
cp -f "$KERNEL_PAYLOAD" kernel

ui_msg "Repacking..."
$MAGISKBOOT repack boot.img boot-new.img >/dev/null 2>&1 || ui_abort "magiskboot repack failed"
[ -f boot-new.img ] || ui_abort "magiskboot produced no boot-new.img"

# Nothing has been written yet, so a mismatch here costs nothing to refuse.
_kmagic_old=$(kernel_magic boot.img)
_kmagic_new=$(kernel_magic boot-new.img)
if [ -n "$_kmagic_old" ] && [ "$_kmagic_old" != "$_kmagic_new" ]; then
    ui_error "The repacked kernel is in a different format than this device uses."
    ui_error "Device kernel starts with $_kmagic_old, the new one with $_kmagic_new."
    ui_error "Ship the raw Image so magiskboot can match the device, or put the"
    ui_error "matching pre-compressed image first in KERNEL_PAYLOADS."
    ui_abort "Kernel format mismatch. Nothing was written."
fi
ui_success "Kernel format preserved ($_kmagic_old)."

# 5.7 Work out the AVB layout of THIS device's partition, from the dump
ui_msg "Reading AVB layout from the live partition..."

PART_SIZE="$(blockdev --getsize64 "$BOOT_BLOCK" 2>/dev/null)"
case "$PART_SIZE" in
    ''|*[!0-9]*) PART_SIZE="$(wc -c < boot.img 2>/dev/null)" ;;
esac
case "$PART_SIZE" in
    ''|*[!0-9]*) ui_abort "Could not determine the size of $BOOT_BLOCK" ;;
esac
ui_print "  Partition size: $PART_SIZE bytes"

# How much of boot-new.img is the boot image proper? magiskboot may append the
# tail it found; if it did, its own footer tells us where the image ends.
NEW_FILE_SIZE="$(wc -c < boot-new.img)"
IMG_SZ="$NEW_FILE_SIZE"
if [ "$NEW_FILE_SIZE" -gt 64 ] && [ $(( NEW_FILE_SIZE % 64 )) -eq 0 ]; then
    dd if=boot-new.img of=.nfoot bs=64 skip=$(( NEW_FILE_SIZE / 64 - 1 )) count=1 2>/dev/null
    if [ "$(hex4_at .nfoot 0)" = "$AVBF_HEX" ]; then
        slice .nfoot .nfo 12 8
        _cand="$(be64_read .nfo)"
        if [ -n "$_cand" ] && [ "$_cand" -gt 0 ] && [ "$_cand" -lt "$NEW_FILE_SIZE" ]; then
            IMG_SZ="$_cand"
            ui_print "  magiskboot appended a tail; boot image ends at $IMG_SZ"
        fi
    fi
    rm -f .nfoot .nfo
fi

# AVB tail taken from the dump of this very partition
AVB_OK=0
if [ $(( PART_SIZE % 64 )) -eq 0 ]; then
    dd if=boot.img of=.avbf bs=64 skip=$(( PART_SIZE / 64 - 1 )) count=1 2>/dev/null
    if [ "$(hex4_at .avbf 0)" = "$AVBF_HEX" ]; then
        slice .avbf .avbo 20 8
        slice .avbf .avbs 28 8
        OLD_OFF="$(be64_read .avbo)"
        VB_SZ="$(be64_read .avbs)"
        if [ "$OLD_OFF" -gt 0 ] && [ "$VB_SZ" -gt 0 ] && \
           [ $(( OLD_OFF % 512 )) -eq 0 ] && [ "$OLD_OFF" -lt "$PART_SIZE" ] && \
           [ "$(hex4_at boot.img "$OLD_OFF")" = "$AVB0_HEX" ]; then
            dd if=boot.img of=.vbmeta bs=512 skip=$(( OLD_OFF / 512 )) \
               count=$(( (VB_SZ + 511) / 512 )) 2>/dev/null
            AVB_OK=1
            ui_print "  Stock vbmeta: $VB_SZ bytes, currently at offset $OLD_OFF"
        else
            ui_warn "Footer present but vbmeta blob not found where it points."
        fi
    else
        ui_print "  No AVB footer on this partition; nothing to preserve."
    fi
fi

# Everything has to fit: image, then the blob, then the footer at the very end.
if [ "$AVB_OK" = "1" ]; then
    NEED=$(( IMG_SZ + VB_SZ ))
    [ "$NEED" -le $(( PART_SIZE - 64 )) ] || \
        ui_abort "Image ($IMG_SZ) + vbmeta ($VB_SZ) exceeds $BOOT_BLOCK ($PART_SIZE). Refusing to write."
    [ $(( IMG_SZ % 512 )) -eq 0 ] || \
        ui_abort "Boot image size $IMG_SZ is not 512-byte aligned. Refusing to write."
else
    [ "$IMG_SZ" -le "$PART_SIZE" ] || \
        ui_abort "Image ($IMG_SZ) is larger than $BOOT_BLOCK ($PART_SIZE). Refusing to write."
fi

# 5.8 Flash: boot image, then this device's own vbmeta blob, then its footer
ui_msg "Writing repacked image to $BOOT_BLOCK..."
blockdev --setrw "$BOOT_BLOCK" 2>/dev/null || true

avb_restore_and_die() {
    ui_error "$1"
    ui_msg "Restoring the original partition from the dump taken a moment ago..."
    if sb_dd if=boot.img of="$BOOT_BLOCK" bs=4096 conv=notrunc; then
        sync
        blockdev --flushbufs "$BOOT_BLOCK" 2>/dev/null || true
        ui_success "Partition restored to its previous contents. Device still bootable."
    else
        ui_error "RESTORE FAILED: $(dd_why)"
        ui_error "Do NOT reboot. Reflash boot via fastboot before powering off."
    fi
    ui_abort "Installation aborted without changing the installed kernel."
}

if ! sb_dd if=boot-new.img of="$BOOT_BLOCK" bs=512 count=$(( IMG_SZ / 512 )) conv=notrunc; then
    avb_restore_and_die "Failed writing the boot image to $BOOT_BLOCK: $(dd_why)"
fi

if [ "$AVB_OK" = "1" ]; then
    ui_msg "Placing the device's own signed vbmeta at offset $IMG_SZ..."
    if ! sb_dd if=.vbmeta of="$BOOT_BLOCK" bs=512 seek=$(( IMG_SZ / 512 )) conv=notrunc; then
        avb_restore_and_die "Failed writing the vbmeta blob: $(dd_why)"
    fi

    # Footer: same bytes as the stock one, with the two offsets moved to match
    # the image we just wrote. Fields 12..19 and 20..27, big-endian.
    slice .avbf .fh 0 12
    slice .avbf .ft 28 36
    be64_write "$IMG_SZ" > .fo
    cat .fh .fo .fo .ft > .avbf-new
    if [ "$(wc -c < .avbf-new)" != "64" ]; then
        avb_restore_and_die "Internal error building the AVB footer"
    fi
    # Cross-check with a different encoder. %08x involves no shifting, so it
    # cannot fail the way the byte encoder above can on a 32-bit shell -- and
    # re-decoding with be64_read would not catch it, since that would only
    # confirm the encoder agrees with itself.
    _want="00000000$(printf '%08x' "$IMG_SZ")"
    if [ "$(hexn .avbf-new 12 8)" != "$_want" ] || [ "$(hexn .avbf-new 20 8)" != "$_want" ]; then
        ui_error "Footer fields encoded wrong: expected $_want,"
        ui_error "got $(hexn .avbf-new 12 8) / $(hexn .avbf-new 20 8)."
        avb_restore_and_die "Refusing to write a footer this shell built incorrectly"
    fi
    if ! sb_dd if=.avbf-new of="$BOOT_BLOCK" bs=64 seek=$(( PART_SIZE / 64 - 1 )) \
            count=1 conv=notrunc; then
        avb_restore_and_die "Failed writing the AVB footer: $(dd_why)"
    fi
fi

sync
ui_success "Write operation completed."

# 5.9 Read the AVB tail back off the block and prove it is coherent
if [ "$AVB_OK" = "1" ]; then
    ui_msg "Verifying AVB chain on $BOOT_BLOCK..."
    blockdev --flushbufs "$BOOT_BLOCK" 2>/dev/null || true
    ( echo 3 > /proc/sys/vm/drop_caches ) 2>/dev/null || true

    dd if="$BOOT_BLOCK" of=.chk bs=64 skip=$(( PART_SIZE / 64 - 1 )) count=1 2>/dev/null
    if [ "$(hex4_at .chk 0)" != "$AVBF_HEX" ]; then
        avb_restore_and_die "No AVB footer at the end of the partition after writing."
    fi
    slice .chk .chko 20 8
    CHK_OFF="$(be64_read .chko)"
    if [ "$CHK_OFF" != "$IMG_SZ" ]; then
        avb_restore_and_die "Footer points at $CHK_OFF but the image ends at $IMG_SZ."
    fi
    if [ "$(hex4_at "$BOOT_BLOCK" "$CHK_OFF")" != "$AVB0_HEX" ]; then
        avb_restore_and_die "No signed vbmeta at offset $CHK_OFF on the partition."
    fi
    ui_success "AVB chain verified: footer at $(( PART_SIZE - 64 )) -> vbmeta at $CHK_OFF."
    rm -f .chk .chko
fi

rm -f .avbf .avbo .avbs .avbf-new .vbmeta .fh .ft .fo .peek .peek4
PAYLOAD_SIZE="$IMG_SZ"
export PAYLOAD_SIZE


# ==============================================================================
# 7. LIFECYCLE: POST-FLASH
# ==============================================================================
if ! load_module "modules/post-flash.sh"; then
    sync
    blockdev --flushbufs "$BOOT_BLOCK" 2>/dev/null || true
    ui_success "Kernel written to $BOOT_BLOCK. Reboot to start it."
fi

# ==============================================================================
# 8. EXTRAS: optional drop-in add-ons
# ==============================================================================
# Everything here is optional by definition, so a failure warns and the install
# still stands. See extras/README for the contract.
if [ -d extras ]; then
    for addon in extras/*.sh; do
        [ -f "$addon" ] || continue
        ui_msg "Add-on: $(basename "$addon")"
        load_module "$addon" || ui_warn "Add-on $(basename "$addon") failed; install is unaffected."
    done
fi

sb_cleanup
exit 0
