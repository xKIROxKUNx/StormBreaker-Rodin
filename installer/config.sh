#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# Everything project-specific lives here.
#
# Adapting this installer to another kernel should mean: edit this file,
# replace banner.txt, drop in your kernel image. Nothing under modules/ or in
# flasher.sh should need touching.

# --- identity ----------------------------------------------------------------
KERNEL_NAME="StormBreaker"
KERNEL_STRING="StormBreaker-Rodin"

# --- target -------------------------------------------------------------------
# Partition that receives the kernel. The A/B slot suffix is appended at runtime.
TARGET_PARTITION="boot"

# Where to look for that partition, in order. Globs allowed.
BLOCK_SEARCH_PATHS="/dev/block/mapper /dev/block/by-name /dev/block/bootdevice/by-name /dev/block/platform/*/by-name"

# Kernel images to look for in the package, in order of preference.
#
# The raw "Image" comes first on purpose. magiskboot only compresses a payload
# that is not already compressed, so handing it "Image.lz4" pins lz4 onto the
# target whatever its bootloader expects -- right for a MediaTek device that
# uses lz4_legacy, wrong for one that boots gzip. The raw image lets magiskboot
# re-compress with the format it found in that device's own boot image, and the
# engine verifies afterwards that the format did come out matching.
#
# Cost: the raw image is ~38 MB extracted (it deflates to ~15 MB in the zip, so
# the package is actually smaller than one carrying Image.lz4). Add a
# pre-compressed image ahead of it here if extraction space matters more than
# portability on your target.
KERNEL_PAYLOADS="Image Image.lz4 Image.gz"

# --- compatibility gate --------------------------------------------------------
# Codenames this kernel was built and tested for. A device outside the list only
# warns: on GKI what decides compatibility is the KMI, not the marketing name.
SUPPORTED_DEVICES="rodin redmi_turbo4 poco_x7_pro"

# KMI generation this kernel implements, as it appears in a vendor module's
# vermagic ("6.6.30-android15-8-ab12345"). A mismatch means every vendor module
# on the device is rejected: no display, no touch, no boot. Fatal.
# Empty disables the check.
REQUIRE_KMI="android15-8"

# Page size this kernel was built for, in KiB. A 4k kernel cannot run a 16k
# userspace, nor the reverse. Fatal. Empty disables the check.
REQUIRE_PAGE_SIZE_KB="4"
