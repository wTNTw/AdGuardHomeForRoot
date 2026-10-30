# add busybox to PATH
[ -d "/data/adb/magisk" ] && export PATH="/data/adb/magisk:$PATH"
[ -d "/data/adb/ksu/bin" ] && export PATH="/data/adb/ksu/bin:$PATH"
[ -d "/data/adb/ap/bin" ] && export PATH="/data/adb/ap/bin:$PATH"

# most of the users are Chinese, so set default language to Chinese
language="zh"

# try to get the system language
locale=$(getprop persist.sys.locale || getprop ro.product.locale || getprop persist.sys.language)

# if the system language is English, set language to English
if echo "$locale" | grep -qi "en"; then
  language="en"
fi

function log() {
  local timestamp
  timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  local str
  [ "$language" = "en" ] && str="$timestamp $1" || str="$timestamp $2"
  echo "$str" | tee -a "$AGH_DIR/history.log"
}

function update_description() {
  local description
  [ "$language" = "en" ] && description="$1" || description="$2"
  local module_id
  module_id=$(grep "^id=" "$MOD_PATH/module.prop" | cut -d'=' -f2)
  # use ksu api if available, otherwise fallback to ap api, and finally fallback to sed
  if [ -x /data/adb/ksud ]; then
    # ksud reads the module id from KSU_MODULE; MODULE_ID is kept for older builds
    KSU_MODULE="$module_id" MODULE_ID="$module_id" /data/adb/ksud module config set override.description "$description"
  elif [ -x /data/adb/apd ]; then
    MODULE_ID="$module_id" /data/adb/apd module config set override.description "$description"
  else
    sed -i "/^description=/c\description=$description" "$MOD_PATH/module.prop"
  fi
}

# Stop the background helpers (inotify watcher + watchdog) started by service.sh.
#
# The match is done through /proc and every PID killed explicitly. pkill -f cannot
# be used here: on some ROMs it reports success but never terminates a shell
# script (matching plain binaries works, scripts do not), which is exactly how
# duplicate watchers and watchdogs managed to pile up.
#
# Shared by service.sh (dedupe before starting fresh ones) and uninstall.sh
# (leave nothing behind that keeps polling a tool.sh which is about to vanish).
#
# SIGTERM is not enough on its own. VERIFIED on device: a helper blocked in a
# foreground sleep (the watchdog spends its whole life in `sleep $interval`)
# defers SIGTERM until that sleep returns, then goes straight back to sleeping,
# so it survives every sweep. That is the real mechanism behind "pkill reports
# success but the script keeps running" -- and why repeated service.sh runs used
# to stack duplicate helpers. So: ask once, then insist.
function kill_helpers() {
  local p cl pass
  for pass in term kill; do
    for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
      [ "$p" = "$$" ] && continue
      # Processes come and go while /proc is being walked; ignore read failures.
      cl=$( { tr '\0' ' ' < "/proc/$p/cmdline"; } 2>/dev/null )
      case "$cl" in
        *"$SCRIPT_DIR/inotify.sh"*|*"$SCRIPT_DIR/watchdog.sh"*)
          [ "$pass" = term ] && kill "$p" 2>/dev/null || kill -9 "$p" 2>/dev/null
          ;;
      esac
    done
    [ "$pass" = term ] && sleep 1
  done
}
