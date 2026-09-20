#!/bin/sh
# Post-flash module: prove the payload reached the flash, then report.
#
# This is the last line of defence against the failure that matters most: a
# partition that accepts writes and drops them. When that happens every step
# before this one reports success -- dd exits 0, and the AVB check passes
# whenever the new image happens to end where the old one did. Only comparing
# the bytes catches it, so a mismatch here is a failed install, not a warning.

verify_payload() {
    ui_msg "Verifying written image..."

    [ -f boot-new.img ] || ui_abort "boot-new.img is gone; cannot verify the install."

    # Only the range the engine actually wrote. When magiskboot appends its own
    # tail, boot-new.img is longer than the boot image proper, so comparing a
    # trimmed readback against the whole file would differ at EOF.
    _size="${PAYLOAD_SIZE:-$(wc -c < boot-new.img 2>/dev/null)}"
    case "$_size" in ''|*[!0-9]*) ui_abort "Unknown payload size; cannot verify the install." ;; esac
    _mb=$(( _size / 1048576 + 1 ))

    sync
    ( echo 3 > /proc/sys/vm/drop_caches ) 2>/dev/null || true
    blockdev --flushbufs "$BOOT_BLOCK" 2>/dev/null || true

    head -c "$_size" boot-new.img > .expected 2>/dev/null
    if dd if="$BOOT_BLOCK" bs=1M count="$_mb" 2>/dev/null |
       head -c "$_size" | cmp -s - .expected; then
        ui_success "Readback matches: $_size bytes verbatim on $BOOT_BLOCK."
        rm -f .expected 2>/dev/null
    else
        rm -f .expected 2>/dev/null
        ui_error "What is on $BOOT_BLOCK is not what was written."
        ui_error "The partition most likely accepted the write and dropped it,"
        ui_error "which is what happens while Android holds it write-protected."
        avb_restore_and_die "Kernel NOT installed. Flash this zip from recovery."
    fi
}

report() {
    ui_print " "
    ui_print "  Installed : ${KERNEL_STRING:-kernel}"
    [ -f version ] && ui_print "  Release   : $(head -n1 version 2>/dev/null)"
    ui_print "  Partition : $BOOT_BLOCK"
    ui_print " "
    ui_success "Done. Reboot to start the new kernel."
}

verify_payload
report
export POST_FLASH_LOADED=1
