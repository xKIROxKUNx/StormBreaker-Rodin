#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# StormBreaker build script — AOSP android15-6.6 GKI for Xiaomi rodin (MT6899).
#
# Produces:
#   StormBreaker-<ver>[-<variant>].zip      AnyKernel3 flashable
#   StormBreaker-<ver>[-<variant>]-boot.img boot.img repacked from stock
#
# The boot.img is built by round-tripping the device's stock boot.img through
# unpack_bootimg --format=mkbootimg, so every device-specific header field
# (header_version, pagesize, offsets, os_version, security patch level) is
# preserved by construction instead of guessed. That matters: some bootloaders
# reject an image whose SPL is lower than the installed one.

set -Eeuo pipefail

KERNEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$KERNEL_DIR"

# ---------------------------------------------------------------- defaults ---
OUT_DIR="$KERNEL_DIR/out"
DIST_DIR="$KERNEL_DIR/dist"
FRAGMENTS=()
DEFAULT_FRAGMENT="arch/arm64/configs/stormbreaker.fragment"
BASE_DEFCONFIG="gki_defconfig"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-$HOME/Desenvolvimento/toolchains}"
CLANG_VERSION="$(sed -n 's/^CLANG_VERSION=//p' build.config.constants)"
CLANG_DIR="$TOOLCHAIN_DIR/clang-$CLANG_VERSION"
CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/android15-release/clang-$CLANG_VERSION.tar.gz"
# Stock boot.img used as the repack template. Extract it from the device's own
# OTA or dump the partition; override with --stock-boot=PATH or $STOCK_BOOT.
STOCK_BOOT="${STOCK_BOOT:-$KERNEL_DIR/dist/boot-stock.img}"
VARIANT=""
PACKAGER="installer"
PACKAGE_ONLY=0
DO_ALL=0
KEEP_DIST=0
JOBS="$(nproc)"
DO_CLEAN=0
DO_BOOTIMG=1
DO_ZIP=1
ZIP_FALLBACK=0

usage() {
	cat <<EOF
Usage: $0 [options]

  --variant=NAME     suffix appended to the artifact names
  --packager=NAME    zip layout: installer (default) or anykernel (legacy)
  --package-only     skip toolchain/config/build, repackage the existing $OUT_DIR
  --all              empty dist/ once, then build every variant below in turn,
                     each producing its zip and its boot.img
  --keep-dist        do not empty dist/ first (what --all passes to each child)
  --fragment=PATH    config fragment to merge, repeatable and applied in order
                     (default: $DEFAULT_FRAGMENT)
  --out=DIR          build directory (default: $OUT_DIR). Give each variant its
                     own, so one never repackages another's kernel
  --stock-boot=PATH  stock boot.img used as the repack template
                     (default: \$STOCK_BOOT)
  --jobs=N           parallel make jobs (default: nproc = $JOBS)
  --clean            wipe $OUT_DIR before building
  --no-bootimg       skip boot.img generation
  --no-zip           skip AnyKernel3 zip generation
  --config-only      run defconfig + fragment merge, then stop
  -h, --help         this text
EOF
}

CONFIG_ONLY=0
for arg in "$@"; do
	case "$arg" in
	--variant=*)    VARIANT="${arg#*=}" ;;
	--packager=*)   PACKAGER="${arg#*=}" ;;
	--package-only) PACKAGE_ONLY=1 ;;
	--all)          DO_ALL=1 ;;
	--keep-dist)    KEEP_DIST=1 ;;
	--fragment=*)   FRAGMENTS+=("${arg#*=}") ;;
	--out=*)        OUT_DIR="${arg#*=}"; [[ "$OUT_DIR" = /* ]] || OUT_DIR="$KERNEL_DIR/$OUT_DIR" ;;
	--stock-boot=*) STOCK_BOOT="${arg#*=}" ;;
	--jobs=*)       JOBS="${arg#*=}" ;;
	--clean)        DO_CLEAN=1 ;;
	--no-bootimg)   DO_BOOTIMG=0 ;;
	--no-zip)       DO_ZIP=0 ;;
	--config-only)  CONFIG_ONLY=1 ;;
	-h|--help)      usage; exit 0 ;;
	*) echo "unknown option: $arg" >&2; usage >&2; exit 2 ;;
	esac
done

(( ${#FRAGMENTS[@]} )) || FRAGMENTS=("$DEFAULT_FRAGMENT")

# Every variant this repository ships:  name | out dir | --variant | fragment
VARIANTS_ALL=(
	"clean|out-vanilla||"
)

# ------------------------------------------------------------------ output ---
BOLD=$'\033[1m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
step() { printf '%s==> %s%s\n' "$BOLD" "$*" "$RST"; }
warn() { printf '%s!!  %s%s\n' "$YEL" "$*" "$RST" >&2; }
die()  { printf '%sXX  %s%s\n' "$RED" "$*" "$RST" >&2; exit 1; }
ok()   { printf '%s ok %s%s\n' "$GRN" "$*" "$RST"; }

BUILD_START="$(date +%s)"
trap 'die "failed at line $LINENO"' ERR

# A working tree may define variants of its own -- a build with a root solution
# added, say -- without touching this script or the repository.
[[ -r "$KERNEL_DIR/local/variants.local" ]] && . "$KERNEL_DIR/local/variants.local"

# ------------------------------------------------------------------- dist ---
# dist/ holds this run's output and nothing else. A stale zip sitting next to a
# fresh one is how the wrong file gets flashed -- and by now some of those stale
# ones predate fixes that matter, so leaving them around is a hazard, not a
# convenience.
#
# The exception is what the build cannot recreate: the stock boot dump and the
# recovery image are the way back from a bad flash. They are inputs kept here
# for convenience, not artifacts.
DIST_KEEP=( "boot-stock.img" "OrangeFox-*.img" )

clean_dist() {
	mkdir -p "$DIST_DIR"
	local f base pat keep removed=0
	for f in "$DIST_DIR"/*; do
		[[ -e "$f" ]] || continue
		base="$(basename "$f")"
		keep=0
		for pat in "${DIST_KEEP[@]}"; do
			# shellcheck disable=SC2053
			[[ "$base" == $pat ]] && { keep=1; break; }
		done
		if (( keep )); then
			printf '    keeping %s\n' "$base"
		else
			rm -rf "$f"
			removed=$(( removed + 1 ))
		fi
	done
	ok "dist/ cleaned ($removed removed)"
}

# ------------------------------------------------------------- all variants ---
if (( DO_ALL )); then
	step "Building every variant into a clean dist/"
	clean_dist
	fwd=( "--jobs=$JOBS" "--stock-boot=$STOCK_BOOT" "--keep-dist" )
	(( DO_CLEAN ))     && fwd+=( --clean )
	(( PACKAGE_ONLY )) && fwd+=( --package-only )
	(( DO_BOOTIMG ))   || fwd+=( --no-bootimg )
	(( DO_ZIP ))       || fwd+=( --no-zip )
	for spec in "${VARIANTS_ALL[@]}"; do
		IFS='|' read -r v_name v_out v_variant v_frag <<<"$spec"
		printf '\n'
		step "variant: $v_name"
		args=( "${fwd[@]}" "--out=$v_out" "--fragment=$DEFAULT_FRAGMENT" )
		[[ -n "$v_frag" ]]    && args+=( "--fragment=$v_frag" )
		[[ -n "$v_variant" ]] && args+=( "--variant=$v_variant" )
		"$0" "${args[@]}" || die "variant $v_name failed"
	done
	printf '\n'
	step "All variants built in $(( ($(date +%s) - BUILD_START) / 60 ))m $(( ($(date +%s) - BUILD_START) % 60 ))s"
	ls -la "$DIST_DIR"
	exit 0
fi

if (( ! KEEP_DIST )) && (( ! CONFIG_ONLY )); then
	step "Clearing dist/"
	clean_dist
fi

# ------------------------------------------------------------ dependencies ---
step "Checking host dependencies"
missing=()
# bc is not optional: kernel/time/Makefile generates timeconst.h with it.
# pahole is needed because gki_defconfig sets CONFIG_DEBUG_INFO_BTF=y.
for t in make curl tar python3 lz4 find bc bison flex perl rsync cpio openssl pahole; do
	command -v "$t" >/dev/null || missing+=("$t")
done
if (( ! CONFIG_ONLY )); then
	# `zip` is optional: python3's zipfile is a perfectly good fallback, and
	# AnyKernel3's update-binary chmods tools/ itself, so we do not depend on
	# the archive carrying exec bits.
	if (( DO_ZIP )) && ! command -v zip >/dev/null; then
		ZIP_FALLBACK=1
	fi
	if (( DO_BOOTIMG )); then
		command -v mkbootimg      >/dev/null || missing+=("mkbootimg (android-tools)")
		command -v unpack_bootimg >/dev/null || missing+=("unpack_bootimg (android-tools)")
	fi
fi
if (( ${#missing[@]} )); then
	printf 'missing required tool(s):\n' >&2
	printf '  - %s\n' "${missing[@]}" >&2
	if command -v pacman >/dev/null; then
		printf '\ntry: sudo pacman -S --needed %s\n' "${missing[*]}" >&2
	fi
	die "install them and re-run"
fi
ok "all present"

if (( PACKAGE_ONLY )); then
step "Package-only: reusing the build already in $OUT_DIR"
[[ -f "$OUT_DIR/include/config/kernel.release" ]] ||
	die "no previous build in $OUT_DIR — run without --package-only first"
ok "$(cat "$OUT_DIR/include/config/kernel.release")"
else
# --------------------------------------------------------------- toolchain ---
step "Toolchain: AOSP clang $CLANG_VERSION"
if [[ -x "$CLANG_DIR/bin/clang" ]]; then
	ok "cached at $CLANG_DIR"
else
	warn "not found, downloading (~600 MB)"
	mkdir -p "$CLANG_DIR"
	tmp="$(mktemp -d)"
	curl -fL --progress-bar -o "$tmp/clang.tar.gz" "$CLANG_URL" \
		|| die "download failed: $CLANG_URL"
	tar -xzf "$tmp/clang.tar.gz" -C "$CLANG_DIR" || die "extract failed"
	rm -rf "$tmp"
	[[ -x "$CLANG_DIR/bin/clang" ]] || die "clang missing after extract"
	ok "installed to $CLANG_DIR"
fi
export PATH="$CLANG_DIR/bin:$PATH"

# scripts/setlocalversion appends a "+" when LOCALVERSION_AUTO is off and the
# tree is not sitting on an annotated tag. Its own comment states the supported
# way out: "If the variable LOCALVERSION is set (including being set to an empty
# string), we don't want to append a plus sign." So export it empty rather than
# patching setlocalversion (which is what the old Capybara tree did).
export LOCALVERSION=""

CLANG_STRING="$("$CLANG_DIR/bin/clang" --version | head -n1)"
printf '    %s\n' "$CLANG_STRING"

# The AOSP toolchain is self-contained; point the build at its binutils too.
MAKE_ARGS=(
	-j"$JOBS"
	O="$OUT_DIR"
	ARCH=arm64
	LLVM=1
	LLVM_IAS=1
	CC=clang
	KCFLAGS=-D__ANDROID_COMMON_KERNEL__
)

# ------------------------------------------------------------------ config ---
if (( DO_CLEAN )); then
	step "Cleaning $OUT_DIR"
	rm -rf "$OUT_DIR"
fi
mkdir -p "$OUT_DIR"

frag_names=""
for f in "${FRAGMENTS[@]}"; do
	[[ -f "$f" ]] || die "fragment not found: $f"
	frag_names+=" + $(basename "$f")"
done
step "Config: $BASE_DEFCONFIG$frag_names"
make "${MAKE_ARGS[@]}" "$BASE_DEFCONFIG" >/dev/null
# merge_config.sh reports every symbol the fragments override -- that report is
# the audit trail of what StormBreaker changes relative to stock AOSP.
./scripts/kconfig/merge_config.sh -m -O "$OUT_DIR" "$OUT_DIR/.config" "${FRAGMENTS[@]}"
make "${MAKE_ARGS[@]}" olddefconfig >/dev/null

for sym in CONFIG_SCHED_BORE CONFIG_MQ_IOSCHED_ADIOS CONFIG_MQ_IOSCHED_DEFAULT_ADIOS \
           CONFIG_LTO_CLANG_THIN CONFIG_MODVERSIONS; do
	if grep -q "^$sym=y" "$OUT_DIR/.config"; then
		ok "$sym=y"
	else
		warn "$sym is NOT enabled in the resolved .config"
	fi
done
grep -q '^# CONFIG_MODULE_SIG_PROTECT is not set' "$OUT_DIR/.config" \
	&& ok "MODULE_SIG_PROTECT disabled" \
	|| warn "MODULE_SIG_PROTECT still enabled — stock vendor modules will be rejected"

(( CONFIG_ONLY )) && { ok "config only, stopping here"; exit 0; }

# ------------------------------------------------------------------- build ---
# Bare `make` would only build Image.gz (the arm64 KBUILD_IMAGE default).
# These are the goals the real GKI build uses (_GKI_AARCH64_MAKE_GOALS in
# BUILD.bazel), and we need Image.lz4 specifically: that is what the stock
# rodin boot.img carries.
step "Building (Image Image.lz4 Image.gz modules) with -j$JOBS"
make "${MAKE_ARGS[@]}" Image Image.lz4 Image.gz modules
fi

BOOT_DIR="$OUT_DIR/arch/arm64/boot"
[[ -f "$BOOT_DIR/Image" ]] || die "no kernel image in $BOOT_DIR"

KERNEL_RELEASE="$(cat "$OUT_DIR/include/config/kernel.release")"
ok "kernel release: $KERNEL_RELEASE"
for img in Image Image.lz4 Image.gz; do
	printf '    %-12s %s\n' "$img" "$(du -h "$BOOT_DIR/$img" | cut -f1)"
done

VERMAGIC="$(strings -a "$BOOT_DIR/Image" | grep -m1 '^vermagic=' || true)"
[[ -n "$VERMAGIC" ]] && printf '    %s\n' "$VERMAGIC"

# Check what the binary actually contains, not what the config claims or what
# the file is named: a build that enables a root solution has to carry it, and
# one that does not must not. Those implementations export symbols prefixed
# ksu_.
KSU_SYMS="$(strings -a "$BOOT_DIR/Image" | grep -c 'ksu_' || true)"
if grep -q '^CONFIG_KSU=y' "$OUT_DIR/.config"; then
	(( KSU_SYMS > 0 )) || die "CONFIG_KSU=y but the Image carries no ksu_ symbols"
	ok "root: present ($KSU_SYMS ksu_ strings in Image)"
else
	(( KSU_SYMS == 0 )) || die "root is off in .config but the Image carries $KSU_SYMS ksu_ strings"
	ok "root: none (0 ksu_ strings in Image)"
fi

# Same rule for the congestion control: the artifact does not get to claim
# BBRv3 because a Kconfig symbol says so. BBRv1 is always there (AOSP builds it
# in), so what is checked is the v3 port specifically, and that the default the
# kernel will actually use is the one the config asked for.
BBR3_SYMS="$(strings -a "$BOOT_DIR/Image" | grep -c 'bbr3' || true)"
DEFAULT_CC="$(sed -n 's/^CONFIG_DEFAULT_TCP_CONG="\(.*\)"$/\1/p' "$OUT_DIR/.config")"
if grep -q '^CONFIG_TCP_CONG_BBR3=y' "$OUT_DIR/.config"; then
	(( BBR3_SYMS > 0 )) || die "CONFIG_TCP_CONG_BBR3=y but the Image carries no bbr3 strings"
	ok "congestion control: BBRv3 present ($BBR3_SYMS bbr3 strings in Image)"
else
	(( BBR3_SYMS == 0 )) || die "BBRv3 is off in .config but the Image carries $BBR3_SYMS bbr3 strings"
	ok "congestion control: BBRv3 absent (0 bbr3 strings in Image)"
fi
if [[ "$DEFAULT_CC" == "bbr3" ]] && ! grep -q '^CONFIG_TCP_CONG_BBR3=y' "$OUT_DIR/.config"; then
	die "CONFIG_DEFAULT_TCP_CONG=\"bbr3\" but BBRv3 is not built in"
fi
printf '    default congestion control: %s\n' "${DEFAULT_CC:-<unset>}"

# Artifact name uses the plain upstream version (e.g. 6.6.142), not the full
# kernel release: "StormBreaker-6.6.142-StormBreaker-4k" would say StormBreaker
# twice. The full release string is still recorded in the zip's `version` file
# and in uname.
BASE_VERSION="$(make -s kernelversion 2>/dev/null || true)"
[[ -z "$BASE_VERSION" ]] && BASE_VERSION="$KERNEL_RELEASE"
NAME="StormBreaker-${BASE_VERSION}"
[[ -n "$VARIANT" ]] && NAME="${NAME}-${VARIANT}"
mkdir -p "$DIST_DIR"

# --------------------------------------------------------------------- zip ---
make_zip() { # <stage dir> <absolute output path>
	rm -f "$2"
	if (( ZIP_FALLBACK )); then
		warn "zip(1) not installed, using python3 zipfile"
		python3 - "$1" "$2" <<-'PYZIP'
			import os, sys, zipfile
			stage, out = sys.argv[1], sys.argv[2]
			with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
			    for root, dirs, files in os.walk(stage):
			        for f in sorted(files):
			            full = os.path.join(root, f)
			            rel = os.path.relpath(full, stage)
			            if rel.startswith('.'):
			                continue
			            z.write(full, rel)
		PYZIP
	else
		( cd "$1" && zip -r9 -q "$2" . -x '.*' )
	fi
}

if (( DO_ZIP )); then
	stage="$(mktemp -d)"
	zip_path="$DIST_DIR/${NAME}.zip"

	case "$PACKAGER" in
	installer)
		step "Packaging modular installer zip"
		src="$KERNEL_DIR/installer"
		[[ -d "$src" ]] || die "installer/ directory missing"

		# Which kernel image to ship is decided by the installer's own
		# config.sh, so the package and the thing that reads it cannot
		# disagree about what is expected to be inside.
		payload="$(sed -n 's/^KERNEL_PAYLOADS="\([^" ]*\).*/\1/p' "$src/config.sh" | head -n1)"
		[[ -n "$payload" ]] || payload="Image"
		[[ -f "$BOOT_DIR/$payload" ]] ||
			die "config.sh asks for $payload, which this build did not produce"
		printf '    payload: %s (%s)\n' "$payload" "$(du -h "$BOOT_DIR/$payload" | cut -f1)"

		cp -a "$src/." "$stage/"
		rm -f "$stage"/Image "$stage"/Image.gz "$stage"/Image.lz4
		rm -f "$stage"/.[!.]* 2>/dev/null || true
		cp "$BOOT_DIR/$payload" "$stage/$payload"

		printf '%s\n%s\n' "$KERNEL_RELEASE${VARIANT:+ ($VARIANT)}" \
			"$(date '+%Y-%m-%d %H:%M')" > "$stage/version"

		# Say the variant where a user will actually see it, so a
		# variant package is never mistaken for the default one.
		if [[ -n "$VARIANT" ]]; then
			sed -i "s/^\(  Features: .*\)$/\1 | $VARIANT/" "$stage/banner.txt"
			sed -i "s/^kernel\.string=\(.*\)$/kernel.string=\1-$VARIANT/" "$stage/anykernel.sh"
		fi

		chmod 755 "$stage"/*.sh "$stage/tools"/* "$stage/modules"/*.sh \
			"$stage/META-INF/com/google/android/update-binary"
		[[ -d "$stage/extras" ]] && chmod 755 "$stage/extras" || true

		# A broken script here becomes a broken flash, and the device that
		# finds out is the one being flashed.
		for f in "$stage"/*.sh "$stage/modules"/*.sh "$stage/extras"/*.sh \
		         "$stage/META-INF/com/google/android/update-binary"; do
			[[ -f "$f" ]] || continue
			sh -n "$f" || die "syntax error in $(basename "$f")"
		done
		ok "shell syntax checked"
		;;
	anykernel)
		step "Packaging AnyKernel3 zip (legacy)"
		[[ -d "$KERNEL_DIR/anykernel" ]] || die \
			"--packager=anykernel needs an anykernel/ directory at $KERNEL_DIR, which is not part of this repository: drop an AnyKernel3 checkout there, or use the default --packager=installer"
		cp -a "$KERNEL_DIR/anykernel/." "$stage/"
		cp "$BOOT_DIR/Image.lz4" "$stage/Image.lz4"
		printf '%s\n%s\n' "$KERNEL_RELEASE" "$(date '+%Y-%m-%d %H:%M')" > "$stage/version"
		chmod 755 "$stage/tools"/* "$stage/META-INF/com/google/android/update-binary"
		zip_path="$DIST_DIR/${NAME}-AK3.zip"
		;;
	*)
		die "unknown packager: $PACKAGER (use installer or anykernel)"
		;;
	esac

	make_zip "$stage" "$zip_path"
	rm -rf "$stage"
	ok "$zip_path ($(du -h "$zip_path" | cut -f1))"
fi

# ---------------------------------------------------------------- boot.img ---
if (( DO_BOOTIMG )); then
	step "Repacking boot.img from stock template"
	if [[ ! -f "$STOCK_BOOT" ]]; then
		warn "stock boot.img not found: $STOCK_BOOT"
		warn "skipping boot.img — pass --stock-boot=PATH to enable"
	else
		work="$(mktemp -d)"
		# --format=mkbootimg prints the exact argv that reproduces this
		# image, so the only thing we change is --kernel. The output is
		# shell-quoted (an empty cmdline comes out as --cmdline ''), so it
		# has to be parsed by the shell -- splitting on spaces would turn
		# the empty string into a literal two-quote argument. All paths in
		# it are the ones we just passed in, so eval sees nothing foreign.
		stock_argstr="$(unpack_bootimg --boot_img "$STOCK_BOOT" \
			--out "$work/unpacked" --format=mkbootimg)"
		eval "stock_args=($stock_argstr)"
		filtered=(); skip=0
		for a in "${stock_args[@]}"; do
			if (( skip )); then skip=0; continue; fi
			case "$a" in
			--kernel|--ramdisk|--out|--output|-o) skip=1; continue ;;
			esac
			filtered+=("$a")
		done
		boot_path="$DIST_DIR/${NAME}-boot.img"
		mkbootimg "${filtered[@]}" \
			--kernel "$BOOT_DIR/Image.lz4" \
			--output "$boot_path" \
			|| die "mkbootimg failed"
		# Graft the stock partition's signed AVB vbmeta onto our image.
		#
		# `vbmeta` covers boot as a CHAIN partition -- the authority lives
		# inside the partition itself -- while dtbo/init_boot/vendor_boot are
		# HASH descriptors whose authority is the top-level vbmeta. That is
		# the whole asymmetry: a modified HASH-covered image merely fails its
		# digest, which this bootloader tolerates (that is why a custom
		# recovery's vendor_boot and a patched init_boot both boot while
		# carrying an unsigned Algorithm:NONE footer), whereas a
		# CHAIN-covered image with no vbmeta, or an unsigned one, cannot be
		# resolved at all.
		#
		# A host cannot sign with the ROM's key, so every host-built boot.img
		# fails here -- ours, and equally the pre-built images published by
		# other projects, all of which bootloop on this device while the same
		# kernels flashed through AnyKernel3 boot fine. AnyKernel3 never builds an
		# image: it rewrites the live partition in place, so the stock signed
		# vbmeta rides along untouched.
		#
		# So do the same thing here: keep the stock vbmeta blob byte for byte
		# and only relocate it past the new, larger boot image. Signature,
		# key and rollback index stay valid; only the hash descriptor is now
		# stale -- and measured on the device, that is enough. With this
		# image in boot_b the bootloader reports verifiedbootstate=green and
		# device_state=locked: it demands a vbmeta that is present, valid and
		# signed with the chain's key, but it does not check the descriptor
		# against the bytes it loads. No footer at all, or one signed with
		# Algorithm:NONE, ends in INVALID_METADATA and bootloops instead.
		"$KERNEL_DIR/tools/stormbreaker/graft-avb-footer.py" \
			"$boot_path" "$STOCK_BOOT" "$boot_path.avb" \
			|| die "grafting the stock AVB vbmeta failed"
		mv -f "$boot_path.avb" "$boot_path"
		graft_key="$(avbtool info_image --image "$boot_path" 2>/dev/null \
			| sed -n 's/^ *Public key (sha1): *//p' | head -1)"
		[[ -n "$graft_key" ]] \
			|| die "the grafted image has no readable AVB public key"
		ok "AVB vbmeta grafted, signed by $graft_key"
		rm -rf "$work"
		ok "$boot_path ($(du -h "$boot_path" | cut -f1))"
		printf '    stock vs built header:\n'
		diff <(unpack_bootimg --boot_img "$STOCK_BOOT" --out "$(mktemp -d)" 2>/dev/null) \
		     <(unpack_bootimg --boot_img "$boot_path"  --out "$(mktemp -d)" 2>/dev/null) \
		     | sed 's/^/      /' || true
	fi
fi

# ------------------------------------------------------------------ report ---
BUILD_END="$(date +%s)"
D=$(( BUILD_END - BUILD_START ))
step "Done in $(( D / 60 ))m $(( D % 60 ))s"
ls -lh "$DIST_DIR" | tail -n +2 | awk '{printf "    %-52s %s\n", $9, $5}'
