#!/system/bin/sh

AGH_DIR="/data/adb/agh"
LOG="$AGH_DIR/debug.log"

{
  echo "==== AdGuardHome Debug Log ===="
  date
  echo

  echo "== System Info =="
  uname -a
  echo "Android Version: $(getprop ro.build.version.release)"
  echo "Device: $(getprop ro.product.model)"
  echo "Architecture: $(uname -m)"
  echo

  echo "== AdGuardHome Version =="
  if [ -f "$AGH_DIR/bin/AdGuardHome" ]; then
    "$AGH_DIR/bin/AdGuardHome" --version
  else
    echo "AdGuardHome binary not found"
  fi
  echo

  echo "== Root Method =="
  if [ -d "/data/adb/magisk" ]; then
    echo "Magisk"
  elif [ -d "/data/adb/ksu" ]; then
    echo "KernelSU"
  elif [ -d "/data/adb/ap" ]; then
    echo "APatch"
  else
    echo "Unknown"
  fi
  echo

  echo "== BusyBox Version =="
  [ -d "/data/adb/magisk" ] && export PATH="/data/adb/magisk:$PATH"
  [ -d "/data/adb/ksu/bin" ] && export PATH="/data/adb/ksu/bin:$PATH"
  [ -d "/data/adb/ap/bin" ] && export PATH="/data/adb/ap/bin:$PATH"
  if command -v busybox >/dev/null 2>&1; then
    busybox --version
  else
    echo "BusyBox not found"
  fi

  echo "== AGH Directory Listing =="
  ls -lR "$AGH_DIR"
  echo

  echo "== AGH Bin Log (last 30 lines) =="
  tail -n 30 "$AGH_DIR/bin.log" 2>/dev/null
  echo

  echo "== Module Markers =="
  ls -l /data/adb/modules/AdGuardHome/disable "$AGH_DIR/.stopped" 2>&1
  echo

  echo "== AGH Settings =="
  cat "$AGH_DIR/settings.conf" 2>/dev/null
  echo

  echo "== AGH PID File =="
  cat "$AGH_DIR/bin/agh.pid" 2>/dev/null
  echo

  echo "== Running Processes (AdGuardHome) =="
  # /proc is authoritative: this ROM's ps prints only argv[0] for the resolver and
  # a root-manager session may not see every process at all.
  found=0
  # ls+grep, not a /proc/[0-9]* glob: some vendor kernels expose entries such as
  # /proc/8350_reg, which matches the glob but has no comm file.
  for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    comm=""
    # The brace group swallows the "no such file" notice for processes that exit
    # between the listing and the read; plain `read ... 2>/dev/null` does not.
    { read -r comm <"/proc/$p/comm"; } 2>/dev/null
    if [ "$comm" = "AdGuardHome" ]; then
      echo "PID $p running"
      found=1
    fi
  done
  [ "$found" = 1 ] || echo "no AdGuardHome process"
  echo

  echo "== NFQUEUE listeners =="
  cat /proc/net/netfilter/nfnetlink_queue 2>/dev/null
  echo

  echo "== iptables -t nat -L -n -v =="
  iptables -t nat -L -n -v
  echo

  echo "== ip6tables -t nat -L -n -v =="
  ip6tables -t nat -L -n -v
  echo

  # The chains that are actually reported broken (IPv6 blocking, SNI) live in the
  # filter table, which the nat dump above never showed.
  echo "== iptables -t filter -S =="
  iptables -t filter -S
  echo

  echo "== ip6tables -t filter -S =="
  ip6tables -t filter -S
  echo

  echo "== Network Interfaces =="
  ip addr
  echo

} >"$LOG" 2>&1

echo "Debug info collected in $LOG"
