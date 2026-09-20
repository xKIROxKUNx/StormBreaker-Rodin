#!/bin/sh
# Test harness: runs the AVB core against a simulated boot partition.
ui_print(){ printf '      %s\n' "$*"; }
ui_msg(){ printf '   == %s\n' "$*"; }
ui_warn(){ printf '   !! %s\n' "$*"; }
ui_error(){ printf '   XX %s\n' "$*"; }
ui_success(){ printf '   ok %s\n' "$*"; }
ui_abort(){ ui_error "$*"; printf '   [ABORTED]\n'; exit 7; }
cd "$WORK" || exit 1
BOOT_BLOCK="$WORK/fakeblock"
. "$CORE"
printf '   PAYLOAD_SIZE=%s\n' "$PAYLOAD_SIZE"
