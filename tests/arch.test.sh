#!/bin/bash
# Unit-tests the architecture guard in src/customize.sh.
#
# The guard reads e_machine out of the ELF inside the zip and compares it with
# the device architecture, because the update channel can only point at one
# asset: an armv7 device updating through the root manager receives the arm64
# package and would otherwise install a module whose core cannot exec.
#
# The function under test is lifted verbatim out of customize.sh, so the test
# fails if the extractor markers (the function definitions) are renamed.
set -u
cd "$(dirname "$0")/.." || exit 1

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FN="$WORK/guard.sh"
sed -n '/^elf_machine()/,/^check_package_arch$/p' src/customize.sh > "$FN"
if [ ! -s "$FN" ]; then
  echo "FAIL  could not extract the architecture guard from src/customize.sh"
  exit 1
fi

make_zip() {  # $1 = e_machine hex pair, $2 = output zip
  python3 - "$1" "$2" <<'PY'
import sys, zipfile
machine = bytes.fromhex(sys.argv[1])
blob = bytearray(4096)
blob[0:4] = b"\x7fELF"
blob[18:20] = machine
with zipfile.ZipFile(sys.argv[2], "w") as z:
    z.writestr("bin/AdGuardHome", bytes(blob))
PY
}

make_zip b700 "$WORK/arm64.zip"    # EM_AARCH64
make_zip 2800 "$WORK/arm32.zip"    # EM_ARM
python3 - "$WORK/junk.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("bin/AdGuardHome", b"not an elf at all")
PY

pass=0
fail=0
run_case() {  # $1 label, $2 zip, $3 ARCH, $4 expect (abort|ok), [$5 uname stub]
  local out rc uname_stub="${5:-}" got
  out=$(
    set +e
    if [ -n "$uname_stub" ]; then uname() { echo "$uname_stub"; }; fi
    ui_print() { echo "UI: $1"; }
    abort() { echo "ABORT: $2"; exit 9; }
    error() { abort "$1" "$2"; }
    info() { :; }
    ZIPFILE="$2"
    ARCH="$3"
    . "$FN"
  )
  rc=$?
  got="ok"
  [ "$rc" = 9 ] && got="abort"
  if [ "$got" = "$4" ]; then
    pass=$((pass + 1))
    echo "PASS  $1 -> $got"
  else
    fail=$((fail + 1))
    echo "FAIL  $1 -> $got (expected $4)"
    echo "$out"
  fi
}

run_case "arm64 package on an armv7 device"            "$WORK/arm64.zip" arm     abort
run_case "armv7 package on an arm64 device"            "$WORK/arm32.zip" arm64   abort
run_case "arm64 package on an arm64 device"            "$WORK/arm64.zip" arm64   ok
run_case "armv7 package on an armv7 device"            "$WORK/arm32.zip" arm     ok
run_case "arm64 package, ARCH unset, uname=armv8l"     "$WORK/arm64.zip" ""      abort armv8l
run_case "armv7 package, ARCH unset, uname=aarch64"    "$WORK/arm32.zip" ""      abort aarch64
run_case "non-ELF payload is not judged"               "$WORK/junk.zip"  arm64   ok

# Optional: also exercise a real package if the caller built one.
if [ -f cache/AdGuardHomeForRoot_arm64.zip ]; then
  real=$(
    set +e
    ui_print() { :; }
    abort() { exit 9; }
    error() { abort "$1" "$2"; }
    info() { :; }
    ZIPFILE="cache/AdGuardHomeForRoot_arm64.zip"
    ARCH="arm"
    . "$FN"
  )
  if [ $? = 9 ]; then
    pass=$((pass + 1)); echo "PASS  real arm64 package rejected for ARCH=arm"
  else
    fail=$((fail + 1)); echo "FAIL  real arm64 package accepted for ARCH=arm"
  fi
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
