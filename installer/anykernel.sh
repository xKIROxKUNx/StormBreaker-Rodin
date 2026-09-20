#!/bin/sh
# AnyKernel3 Compatibility Layer for StormBreaker Modular Flasher
# Provides the AnyKernel3 properties block that kernel flasher apps read to
# recognise this zip as installable, then hands over to flasher.sh.
#
# do.devicecheck is 0 on purpose: the real gate is modules/devices.sh, which
# warns on an unknown codename and refuses only on a KMI or page size mismatch.
# Claiming 1 here would advertise a hard codename check that does not happen.
# Keep the values below in sync with config.sh.

properties() { '
kernel.string=StormBreaker-Rodin
do.devicecheck=0
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=rodin
device.name2=Rodin
device.name3=redmi_turbo4
device.name4=poco_x7_pro
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

# AnyKernel3 shell variables
block=boot
is_slot_device=auto
ramdisk_compression=auto
patch_vbmeta_flag=auto
no_magisk_check=1

# Determine base directory
CWD="$(cd "$(dirname "$0")" && pwd)"
cd "$CWD" || exit 1

export OUTFD="${OUTFD:-${2:-1}}"
export ZIPFILE="${ZIPFILE:-$3}"

# Delegate to the StormBreaker modular engine
if [ -f "$CWD/flasher.sh" ]; then
    . "$CWD/flasher.sh"
elif [ -f "./flasher.sh" ]; then
    . ./flasher.sh
else
    echo "ui_print [ERROR] StormBreaker flasher.sh engine not found!"
    exit 1
fi
