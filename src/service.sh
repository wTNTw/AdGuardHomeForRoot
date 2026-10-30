until [ "$(getprop init.svc.bootanim)" = "stopped" ]; do
  sleep 12
done

. /data/adb/agh/settings.conf
. /data/adb/agh/scripts/base.sh

# A manual stop (WebUI "Stop Core" / action.sh toggle) is deliberately not
# persisted across a reboot: someone who stopped the module once must not end up
# with a dead module after upgrading.
rm -f "$AGH_DIR/.stopped"

# Kill the helpers left behind by a previous run *before* touching the state,
# then start fresh ones. A repeated service.sh run (module update, manual
# re-trigger) used to leave the old instances alive, so a single event was
# delivered twice and a "start" could race a "stop", leaving the DNS hijack
# torn down until reboot. Sweeping first also means no stale watchdog can fire a
# concurrent `ensure` while this one is working.
kill_helpers

# ensure, not start: a core that survived a userspace restart is adopted *and* a
# hijack lost while the module still looked healthy is repaired in this same
# pass, instead of waiting for the first watchdog tick (or forever, when
# watchdog_interval=0).
/data/adb/agh/scripts/tool.sh ensure

# inotifyd has to be the busybox build. The one shipped by the ROM (toybox)
# rejects the "d,n" mask, exits on the spot, and from then on disable/enable
# events are never handled again for the rest of the boot. base.sh puts the
# KernelSU/Magisk busybox first on PATH, but "inotifyd" alone may still resolve
# to /system/bin, so the applet is invoked through busybox explicitly.
#
# Both helpers are detached from our stdio: whoever triggers service.sh by hand
# (a root shell over a pipe) would otherwise wait forever for these children,
# which outlive it. Anything they need to report already goes to history.log.
busybox inotifyd "$SCRIPT_DIR/inotify.sh" "$MOD_PATH:d,n" >/dev/null 2>&1 &

# Watchdog: repairs a lost hijack (dead watcher, missed event, chain wiped by
# another tool) which would otherwise stay broken until the next reboot.
# tool.sh ensure respects the module's "disable" marker and the manual-stop
# marker, so it never fights a user decision. Its own file keeps the command
# line distinct from this script, so the sweep above can tell the two apart.
sh "$SCRIPT_DIR/watchdog.sh" >/dev/null 2>&1 &
