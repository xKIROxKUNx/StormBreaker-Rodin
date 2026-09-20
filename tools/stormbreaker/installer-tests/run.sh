#!/usr/bin/env bash
# Runs the installer test suites against a simulated boot partition.
#
#   ./run.sh [path/to/stock-boot.img]
#
# The image must be a full dump of a real boot partition carrying an AVB
# footer: the tests recolocate that device's own footer and blob, so a
# synthetic image would not prove anything. Defaults to dist/boot-stock.img.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
STOCK="${1:-$ROOT/dist/boot-stock.img}"

[[ -f "$STOCK" ]] || { echo "stock boot image not found: $STOCK" >&2; exit 2; }
# The suites reach the image through a symlink planted in a temporary root, so a
# relative path given here would resolve against the wrong directory -- and the
# only symptom would be six FileNotFoundError tracebacks.
STOCK="$(cd "$(dirname "$STOCK")" && pwd)/$(basename "$STOCK")"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cp -a "$HERE/stubs" "$HERE/harness.sh" "$WORK/"

# The AVB core is tested as it ships: pulled straight out of flasher.sh.
python3 - "$ROOT/installer/flasher.sh" "$WORK/avb-core.sh" <<'PY'
import sys, pathlib
s = pathlib.Path(sys.argv[1]).read_text()
# From the dd wrapper through the AVB helpers: the writes go through sb_dd, so
# the helpers have to come along or the extract would not run.
h0 = s.rindex('# ====', 0, s.index('# 3b. THE dd USED'))
h1 = s.rindex('# ====', h0, s.index('# 5. LIFECYCLE'))
c0 = s.index('# 5.7 Work out the AVB layout')
c1 = s.index('export PAYLOAD_SIZE') + len('export PAYLOAD_SIZE')
pathlib.Path(sys.argv[2]).write_text(s[h0:h1] + "\n" + s[c0:c1] + "\n")
PY

# The suites read the stock image from <root>/dist/boot-stock.img.
if [[ "$STOCK" != "$ROOT/dist/boot-stock.img" ]]; then
	mkdir -p "$WORK/root/dist" "$WORK/root"
	ln -sfn "$ROOT/installer" "$WORK/root/installer"
	ln -sf "$STOCK" "$WORK/root/dist/boot-stock.img"
	ROOT="$WORK/root"
fi

rc=0
for t in test-avb-layout test-avb-degraded test-scenarios test-kernel-format test-dd-parity test-footer-guard; do
	echo; echo "################ $t"
	python3 "$HERE/$t.py" "$WORK" "$ROOT" || rc=1
done
exit $rc
