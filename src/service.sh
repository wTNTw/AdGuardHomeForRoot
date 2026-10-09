until [ $(getprop init.svc.bootanim) = "stopped" ]; do
  sleep 12
done

/data/adb/agh/scripts/tool.sh start

. /data/adb/agh/settings.conf
. /data/adb/agh/scripts/base.sh

# Kill the helpers left behind by a previous run, then start fresh ones. A
# repeated service.sh run (module update, manual re-trigger) used to leave the
# old instances alive, so a single event was delivered twice and a "start" could
# race a "stop", leaving the DNS hijack torn down until reboot.
#
# The match is done through /proc and every PID killed explicitly. pkill -f
# cannot be used here: on some ROMs it reports success but never terminates a
# shell script (matching plain binaries works, scripts do not), which is exactly
# how duplicate watchers and watchdogs managed to pile up.
kill_helpers() {
  local p cl
  for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    [ "$p" = "$$" ] && continue
    # Processes come and go while /proc is being walked; ignore read failures.
    cl=$( { tr '\0' ' ' < "/proc/$p/cmdline"; } 2>/dev/null )
    case "$cl" in
      *"$SCRIPT_DIR/inotify.sh"*|*"$SCRIPT_DIR/watchdog.sh"*)
        kill "$p" 2>/dev/null
        ;;
    esac
  done
}

kill_helpers
sleep 1

# inotifyd has to be the busybox build. The one shipped by the ROM (toybox)
# rejects the "d,n" mask, exits on the spot, and from then on disable/enable
# events are never handled again for the rest of the boot. base.sh puts the
# KernelSU/Magisk busybox first on PATH, but "inotifyd" alone may still resolve
# to /system/bin, so the applet is invoked through busybox explicitly.
busybox inotifyd "$SCRIPT_DIR/inotify.sh" "$MOD_PATH:d,n" &

# Watchdog: repairs a lost hijack (dead watcher, missed event, chain wiped by
# another tool) which would otherwise stay broken until the next reboot.
# tool.sh ensure respects the module's "disable" marker, so it never fights a
# manual module toggle. Its own file keeps the command line distinct from this
# script, so the sweep above can tell the two apart.
sh "$SCRIPT_DIR/watchdog.sh" &
