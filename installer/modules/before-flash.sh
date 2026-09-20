#!/bin/sh
# Pre-flight module: resolve the slot and the target block, and prove the
# partition really takes writes before anything is dumped or modified.
#
# When it does not, the install stops here and says to use recovery. Nothing is
# scheduled and nothing reboots on the user's behalf: on a device that refuses
# the write there is nothing this package can do from a running Android, and a
# flasher app that reboots by itself is worse than one that explains.

detect_slot() {
    _slot=$(getprop ro.boot.slot_suffix 2>/dev/null)
    [ -z "$_slot" ] && _slot=$(grep -o 'androidboot.slot_suffix=[^ ]*' /proc/cmdline 2>/dev/null | cut -d= -f2)
    if [ -z "$_slot" ]; then
        _raw=$(getprop ro.boot.slot 2>/dev/null)
        [ -n "$_raw" ] && [ "$_raw" != "normal" ] && _slot="_$_raw"
    fi
    [ "$_slot" = "normal" ] && _slot=""
    printf '%s' "$_slot"
}

resolve_target_block() {
    _slot="$1"
    for _p in $BLOCK_SEARCH_PATHS; do
        if [ -e "$_p/$TARGET_PARTITION$_slot" ]; then
            printf '%s' "$_p/$TARGET_PARTITION$_slot"; return 0
        elif [ -e "$_p/$TARGET_PARTITION" ]; then
            printf '%s' "$_p/$TARGET_PARTITION"; return 0
        fi
    done
}

# --- does this partition actually take writes? -------------------------------
#
# A write can be accepted and then dropped. On this class of device the UFS
# logical unit holding boot is write-protected while Android is running: the
# page cache takes the data, dd reports success and exits 0, and the writeback
# fails later, asynchronously. The kernel says what happened --
#
#   sd 0:0:0:2: [sdc] Sense Key : 0x7 [current]   <- DATA PROTECT
#                     ASC=0x27 ASCQ=0x0           <- WRITE PROTECTED
#   critical target error, dev sdc, op 0x1:(WRITE)
#   Buffer I/O error on dev sdc71, lost async page write
#
# -- but nothing in userspace sees it. Measured on a rodin: every dd
# implementation, every block size, every offset reports success and writes
# nothing, and conv=fsync returns 0 as well. Reading the partition back does
# not help either while the stale page is still cached.
#
# So the only honest test is to write something *different* and read it back
# after dropping caches. Somewhere safe to do that: past the vbmeta blob the
# partition is padding all the way to the 64-byte footer, so the second-to-last
# page belongs to nobody. The page is put back either way.
SBMARK_HEX=53425754     # "SBWT"

probe_page_offset() {   # <partition size> -> 4096-aligned offset in the padding
    _psz="$1"
    [ $(( _psz % 64 )) -eq 0 ] || return 1
    dd if="$BOOT_BLOCK" of=.pf bs=64 skip=$(( _psz / 64 - 1 )) count=1 2>/dev/null || return 1
    if [ "$(hex4_at .pf 0)" != "$AVBF_HEX" ]; then rm -f .pf; return 1; fi
    slice .pf .pfo 20 8
    slice .pf .pfs 28 8
    _off=$(be64_read .pfo) || { rm -f .pf .pfo .pfs; return 1; }
    _sz=$(be64_read .pfs)  || { rm -f .pf .pfo .pfs; return 1; }
    rm -f .pf .pfo .pfs
    _probe=$(( (_psz - 8192) / 4096 * 4096 ))
    [ "$_probe" -ge $(( _off + _sz + 4096 )) ] || return 1
    printf '%s' "$_probe"
}

# Sets PROBE_WHY so the two failures stay distinguishable: a dd that refuses
# outright says so in its own words, a partition that swallows the write gets
# named for what it did.
partition_takes_writes() {  # <probe offset> -> 0 if a write really lands
    _p="$1"; _seek=$(( _p / 4096 ))
    PROBE_WHY=""
    _orig4="$(hex4_at "$BOOT_BLOCK" "$_p")"
    if ! sb_dd if="$BOOT_BLOCK" of=.ppage bs=4096 skip="$_seek" count=1; then
        PROBE_WHY="$(dd_why)"
        return 1
    fi

    printf 'SBWT' > .pmark
    _rc=0
    if ! sb_dd if=.pmark of="$BOOT_BLOCK" bs=4096 seek="$_seek" count=1 conv=notrunc; then
        PROBE_WHY="$(dd_why)"
        _rc=1
    fi
    sync
    blockdev --flushbufs "$BOOT_BLOCK" 2>/dev/null || true
    ( echo 3 > /proc/sys/vm/drop_caches ) 2>/dev/null || true
    if [ "$(hex4_at "$BOOT_BLOCK" "$_p")" != "$SBMARK_HEX" ]; then
        [ -n "$PROBE_WHY" ] || PROBE_WHY="the device accepted the write and dropped it"
        _rc=1
    fi

    # Put the page back whatever happened, and say so if that fails.
    sb_dd if=.ppage of="$BOOT_BLOCK" bs=4096 seek="$_seek" count=1 conv=notrunc || true
    sync
    blockdev --flushbufs "$BOOT_BLOCK" 2>/dev/null || true
    ( echo 3 > /proc/sys/vm/drop_caches ) 2>/dev/null || true
    if [ "$(hex4_at "$BOOT_BLOCK" "$_p")" != "$_orig4" ]; then
        rm -f .ppage .pmark
        ui_abort "Probe wrote to $BOOT_BLOCK at $_p and could not put it back."
    fi
    rm -f .ppage .pmark
    return $_rc
}

preflight() {
    ui_msg "Pre-flight checks..."

    BOOTMODE=false
    if [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] ||
       [ "$(getprop dev.bootcomplete 2>/dev/null)" = "1" ]; then
        BOOTMODE=true
    elif ps -A 2>/dev/null | grep -q "[z]ygote" || ps 2>/dev/null | grep -q "[z]ygote"; then
        BOOTMODE=true
    fi

    SLOT=$(detect_slot)
    if [ -n "$SLOT" ]; then
        ui_print "  Active slot: $SLOT"
    else
        ui_print "  Slotless partition layout."
    fi

    BOOT_BLOCK=$(resolve_target_block "$SLOT")
    [ -n "$BOOT_BLOCK" ] && [ -e "$BOOT_BLOCK" ] ||
        ui_abort "Partition $TARGET_PARTITION$SLOT not found under: $BLOCK_SEARCH_PATHS"
    ui_print "  Target     : $BOOT_BLOCK"

    blockdev --setrw "$BOOT_BLOCK" 2>/dev/null || true
    _blocked=false
    [ "$(blockdev --getro "$BOOT_BLOCK" 2>/dev/null)" = "1" ] && _blocked=true

    if [ "$_blocked" = "false" ]; then
        _psz="$(blockdev --getsize64 "$BOOT_BLOCK" 2>/dev/null)"
        case "$_psz" in ''|*[!0-9]*) _psz="" ;; esac
        _probe=""
        [ -n "$_psz" ] && _probe="$(probe_page_offset "$_psz")"

        if [ -n "$_probe" ]; then
            if partition_takes_writes "$_probe"; then
                ui_print "  Write test   : passed (data read back at $_probe)"
            else
                _blocked=true
                _why="$PROBE_WHY"
            fi
        else
            # No safe scratch page to prove it with -- rehearse the invocation
            # at least, and let the post-flash readback be the backstop.
            if sb_dd if="$BOOT_BLOCK" of=.wtest bs=512 count=1 &&
               sb_dd if=.wtest of="$BOOT_BLOCK" bs=512 count=1 conv=notrunc; then
                ui_warn "No scratch page found; write capability not proven."
            else
                _blocked=true
                _why="$(dd_why)"
            fi
            rm -f .wtest 2>/dev/null
        fi
    fi

    if [ "$_blocked" = "true" ]; then
        ui_error "$BOOT_BLOCK cannot be written: ${_why:-reported read-only}"
        if [ "$BOOTMODE" = "true" ]; then
            ui_error "The partition is write-protected while Android is running."
            ui_error "The device itself refuses the write, below the kernel, so"
            ui_error "root cannot work around it."
        fi
        ui_print " "
        ui_abort "Install this package from recovery instead."
    fi

    ui_success "Target is writable."
}

preflight
export BEFORE_FLASH_LOADED=1
