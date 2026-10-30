#!/system/bin/sh

# Everything below has to happen while the scripts still exist. Removing
# /data/adb/agh first would leave the port-53 redirect pointing at a binary that
# is already gone: if the resolver process died with it the device resolves
# nothing until the next reboot, and if it is still alive the module keeps
# hijacking DNS while offering no way left to stop it.

if [ -f /data/adb/agh/settings.conf ]; then
  . /data/adb/agh/settings.conf
  . /data/adb/agh/scripts/base.sh

  # No orphan helpers: the watcher and the watchdog would otherwise keep polling
  # a tool.sh that is about to be deleted.
  kill_helpers
fi

if [ -x /data/adb/agh/scripts/tool.sh ]; then
  /data/adb/agh/scripts/tool.sh stop
fi

# Belt and braces for a partial/damaged installation where tool.sh is missing or
# cannot run: dropping the chains twice is harmless, leaving them behind is not.
if [ -x /data/adb/agh/scripts/iptables.sh ]; then
  /data/adb/agh/scripts/iptables.sh disable
fi

rm -rf /data/adb/agh
