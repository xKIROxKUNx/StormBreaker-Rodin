#!/bin/sh
# Compatibility gate.
#
# Policy, and the reason for it: on a GKI kernel the device codename decides
# almost nothing. The boot image is repacked from the target's own partition, so
# header, cmdline, security patch level and the AVB chain all come from that
# device. What actually decides whether this kernel can run there is
#
#   1. the KMI generation its vendor modules were built against, and
#   2. the page size its userspace was built for.
#
# So the codename is a hint and only warns -- a sibling model with the same KMI
# is expected to work. A KMI or page size mismatch is fatal and ends the run
# before anything is written.
#
# Values come from config.sh; leaving REQUIRE_KMI or REQUIRE_PAGE_SIZE_KB empty
# disables that check.

kmi_of() {  # extract "androidNN-M" from a version string
    printf '%s' "$1" | grep -o 'android[0-9][0-9]*-[0-9][0-9]*' 2>/dev/null | head -n1
}

detect_codename() {
    for _prop in ro.product.device ro.build.product ro.product.vendor.device ro.product.name; do
        _dev=$(getprop "$_prop" 2>/dev/null)
        [ -n "$_dev" ] && { printf '%s' "$_dev"; return 0; }
    done
    [ -f /proc/device-tree/model ] && tr -d '\000' < /proc/device-tree/model 2>/dev/null
}

# A vendor module states the KMI it requires, which is exactly the constraint
# that matters -- and it stays readable after this kernel is already installed,
# when uname would report our own version string instead.
kmi_from_modules() {
    for _dir in /vendor/lib/modules /odm/lib/modules /vendor_dlkm/lib/modules; do
        [ -d "$_dir" ] || continue
        for _ko in "$_dir"/*.ko; do
            [ -f "$_ko" ] || continue
            _vm=$(grep -a -o 'vermagic=[^ ]*' "$_ko" 2>/dev/null | head -n1)
            _k=$(kmi_of "$_vm")
            [ -n "$_k" ] && { printf '%s' "$_k"; return 0; }
        done
    done
    return 1
}

detect_kmi() {
    _k=$(kmi_from_modules) && { printf '%s' "$_k"; return 0; }

    # In recovery /vendor is usually not mounted, and the running kernel is
    # already ours, whose version string carries no KMI -- which is how a real
    # recovery run ended up unable to check anything. Mounting it read-only is
    # what puts the modules back in reach. Nothing is mounted here that was
    # mounted already: the lookup above would have found the modules.
    for _m in /vendor /vendor_dlkm; do
        [ -d "$_m" ] && mount -o ro "$_m" 2>/dev/null || mount "$_m" 2>/dev/null || true
    done
    _k=$(kmi_from_modules) && { printf '%s' "$_k"; return 0; }

    # Last resort: the running kernel. Right while the device is still on its
    # stock kernel, silent once it is not.
    kmi_of "$(uname -r 2>/dev/null)"
}

detect_page_size_kb() {
    _kb=$(grep -m1 '^KernelPageSize:' /proc/self/smaps 2>/dev/null | tr -dc '0-9')
    if [ -z "$_kb" ]; then
        _b=$(getconf PAGE_SIZE 2>/dev/null || getconf PAGESIZE 2>/dev/null)
        case "$_b" in ''|*[!0-9]*) _b="" ;; esac
        [ -n "$_b" ] && _kb=$(( _b / 1024 ))
    fi
    printf '%s' "$_kb"
}

check_compatibility() {
    ui_msg "Checking compatibility..."

    # --- codename: informational -------------------------------------------
    _dev=$(detect_codename)
    if [ -z "$_dev" ]; then
        ui_warn "Could not read the device codename."
    else
        ui_print "  Device     : $_dev"
        _match=""
        for _d in $SUPPORTED_DEVICES; do
            case "$_dev" in *"$_d"*) _match="$_d"; break ;; esac
        done
        if [ -z "$_match" ]; then
            ui_warn "'$_dev' is not in this kernel's tested device list."
            ui_warn "Continuing: on GKI the KMI decides, not the codename."
        fi
    fi

    # --- KMI: fatal ---------------------------------------------------------
    if [ -n "$REQUIRE_KMI" ]; then
        _kmi=$(detect_kmi)
        if [ -z "$_kmi" ]; then
            ui_warn "Could not determine this device's KMI generation."
            ui_warn "Expected $REQUIRE_KMI. Proceeding unverified."
        elif [ "$_kmi" != "$REQUIRE_KMI" ]; then
            ui_print "  KMI        : $_kmi"
            ui_error "This kernel implements KMI $REQUIRE_KMI, the device needs $_kmi."
            ui_error "Every vendor module would be rejected: no display, no boot."
            ui_abort "Incompatible KMI. Nothing was written."
        else
            ui_print "  KMI        : $_kmi"
        fi
    fi

    # --- page size: fatal ---------------------------------------------------
    if [ -n "$REQUIRE_PAGE_SIZE_KB" ]; then
        _ps=$(detect_page_size_kb)
        if [ -z "$_ps" ]; then
            ui_warn "Could not determine the device page size."
        elif [ "$_ps" != "$REQUIRE_PAGE_SIZE_KB" ]; then
            ui_print "  Page size  : ${_ps}k"
            ui_error "This kernel is built for ${REQUIRE_PAGE_SIZE_KB}k pages, the device runs ${_ps}k."
            ui_abort "Incompatible page size. Nothing was written."
        else
            ui_print "  Page size  : ${_ps}k"
        fi
    fi

    ui_success "Device is compatible with this kernel."
}

check_compatibility
export DEVICES_LOADED=1
