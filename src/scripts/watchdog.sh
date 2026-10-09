#!/system/bin/sh
# Periodic repair loop for the DNS hijack.
#
# The inotify watcher only reacts to the module's "disable" marker. If that
# watcher ever dies, or an event is missed, the iptables redirect would stay
# gone until the next reboot -- that is the "DNS silently stops resolving and
# ads come back" report. This loop polls the real state and repairs it.
#
# It lives in its own file rather than as an inline subshell inside service.sh
# so that service.sh can dedupe it with a single pkill, exactly like it does
# for the watcher. (An inline subshell gets a service.sh command line, which
# makes it impossible to kill without also killing service.sh itself.)
. /data/adb/agh/settings.conf
. /data/adb/agh/scripts/base.sh

interval="${watchdog_interval:-60}"

# Only a positive integer enables the watchdog; anything else disables it.
case "$interval" in
  ''|*[!0-9]*)
    exit 0
    ;;
esac
[ "$interval" -gt 0 ] || exit 0

while true; do
  sleep "$interval"
  "$SCRIPT_DIR/tool.sh" ensure
done
