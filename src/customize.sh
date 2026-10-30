SKIPUNZIP=1

# most of the users are Chinese, so set default language to Chinese
language="zh"

# try to get the system language
locale=$(getprop persist.sys.locale || getprop ro.product.locale || getprop persist.sys.language)

# if the system language is English, set language to English
if echo "$locale" | grep -qi "en"; then
  language="en"
fi

function info() {
  [ "$language" = "en" ] && ui_print "$1" || ui_print "$2"
}

function error() {
  [ "$language" = "en" ] && abort "$1" || abort "$2"
}

info "- 🚀 Installing AdGuardHome for $ARCH" "- 🚀 开始安装 AdGuardHome for $ARCH"

# The update channel can only point at one asset (version.json -> arm64), so an
# armv7 device that updates through the root manager receives the arm64 package.
# Installing it looks successful and then fails at boot with ENOEXEC, which reads
# as "the module is broken". Refuse early, while both the zip and the working
# installation are still untouched.
elf_machine() {
  # e_machine lives at offset 18 (2 bytes, little endian):
  #   0xB7 0x00 = EM_AARCH64, 0x28 0x00 = EM_ARM
  unzip -p "$ZIPFILE" "bin/AdGuardHome" 2>/dev/null | od -An -j18 -N2 -tx1 2>/dev/null | tr -d ' \n'
}

check_package_arch() {
  local machine need have
  machine=$(elf_machine)
  case "$machine" in
    b700) need="arm64" ;;
    2800) need="arm" ;;
    *) return 0 ;;   # unknown or x86 build: nothing sensible to assert
  esac
  # $ARCH comes from the root manager (arm64 / arm / x86 / x64); uname is the
  # fallback for installers that do not set it. armv8l means 32-bit userspace on
  # a 64-bit kernel, which needs the arm build.
  case "${ARCH:-$(uname -m)}" in
    arm64|aarch64) have="arm64" ;;
    arm|armv7*|armv8l|armv8*) have="arm" ;;
    *) return 0 ;;
  esac
  [ "$need" = "$have" ] && return 0
  error "- ❌ This package is built for $need, but this device is $have. Download AdGuardHomeForRoot_${have}.zip and install that instead." \
    "- ❌ 此安装包为 $need 架构，当前设备是 $have，请改为安装 AdGuardHomeForRoot_${have}.zip"
}

check_package_arch

AGH_DIR="/data/adb/agh"
BIN_DIR="$AGH_DIR/bin"
SCRIPT_DIR="$AGH_DIR/scripts"
PID_FILE="$AGH_DIR/bin/agh.pid"

info "- 📦 Extracting module basic files..." "- 📦 解压模块基本文件..."
unzip -o "$ZIPFILE" "action.sh" -d "$MODPATH" >/dev/null 2>&1 
unzip -o "$ZIPFILE" "module.prop" -d "$MODPATH" >/dev/null 2>&1
unzip -o "$ZIPFILE" "service.sh" -d "$MODPATH" >/dev/null 2>&1
unzip -o "$ZIPFILE" "uninstall.sh" -d "$MODPATH" >/dev/null 2>&1
unzip -o "$ZIPFILE" "webroot/*" -d "$MODPATH" >/dev/null 2>&1

extract_keep_config() {
  info "- 🌈 Keeping old configuration files..." "- 🌈 保留原来的配置文件..."
  info "- 📜 Extracting script files..." "- 📜 正在解压脚本文件..."
  unzip -o "$ZIPFILE" "scripts/*" -d $AGH_DIR >/dev/null 2>&1 || {
    error "- ❌ Failed to extract scripts!" "- ❌ 解压脚本文件失败！"
  }
  info "- 🛠️ Extracting binary files except configuration..." "- 🛠️ 正在解压二进制文件（不包括配置文件）..."
  unzip -o "$ZIPFILE" "bin/*" -x "bin/AdGuardHome.yaml" -d $AGH_DIR >/dev/null 2>&1 || {
    error "- ❌ Failed to extract binary files!" "- ❌ 解压二进制文件失败！"
  }
  info "- 🚫 Skipping configuration file extraction..." "- 🚫 跳过解压配置文件..."
}

extract_no_config() {
  info "- 💾 Backing up old configuration files with .bak extension..." "- 💾 使用 .bak 扩展名备份旧配置文件..."
  [ -f "$AGH_DIR/settings.conf" ] && mv "$AGH_DIR/settings.conf" "$AGH_DIR/settings.conf.bak"
  [ -f "$AGH_DIR/bin/AdGuardHome.yaml" ] && mv "$AGH_DIR/bin/AdGuardHome.yaml" "$AGH_DIR/bin/AdGuardHome.yaml.bak"
  extract_all
}

extract_all() {
  info "- 🌟 Extracting script files..." "- 🌟 正在解压脚本文件..."
  unzip -o "$ZIPFILE" "scripts/*" -d $AGH_DIR >/dev/null 2>&1 || {
    error "- ❌ Failed to extract scripts" "- ❌ 解压脚本文件失败"
  }
  info "- 🛠️ Extracting binary files..." "- 🛠️ 正在解压二进制文件..."
  unzip -o "$ZIPFILE" "bin/*" -d $AGH_DIR >/dev/null 2>&1 || {
    error "- ❌ Failed to extract binary files" "- ❌ 解压二进制文件失败"
  }
  info "- 📜 Extracting configuration files..." "- 📜 正在解压配置文件..."
  unzip -o "$ZIPFILE" "settings.conf" -d $AGH_DIR >/dev/null 2>&1 || {
    error "- ❌ Failed to extract configuration files" "- ❌ 解压配置文件失败"
  }
}

# Print the PIDs of running AdGuardHome processes. Must not fork per process:
# `$(cat /proc/<pid>/comm)` over a device with a thousand processes takes
# seconds, while the read builtin needs none.
#
# ls+grep instead of a /proc/[0-9]* glob: some vendor kernels expose entries like
# /proc/8350_reg, which matches the glob but has no comm file.
agh_pids() {
  local p comm
  for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    comm=""
    # The brace group swallows the "no such file" notice for processes that exit
    # between the listing and the read; plain `read ... 2>/dev/null` does not.
    { read -r comm <"/proc/$p/comm"; } 2>/dev/null
    [ "$comm" = "AdGuardHome" ] || continue
    echo "$p"
  done
}

if [ -d "$AGH_DIR" ]; then
  info "- ⏹️ Found old version, stopping all AdGuardHome processes..." "- ⏹️ 发现旧版模块，正在停止所有 AdGuardHome 进程..."
  # Match /proc/<pid>/comm, not `pkill -f AdGuardHome`: the installer's own
  # command line contains ".../AdGuardHome/customize.sh", so -f kills itself.
  for p in $(agh_pids); do
    kill "$p" 2>/dev/null
  done
  # Give it a moment to shut down cleanly before replacing its binary.
  waited=0
  while [ -n "$(agh_pids)" ] && [ "$waited" -lt 5 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  for p in $(agh_pids); do
    kill -9 "$p" 2>/dev/null
  done
  rm -f "$PID_FILE"
  info "- 🔄 Do you want to keep the old configuration? (If not, it will be automatically backed up)" "- 🔄 是否保留原来的配置文件？（若不保留则自动备份）"
  info "- 🔊 (Volume Up = Yes, Volume Down = No, 30s no input = Yes)" "- 🔊 （音量上键 = 是, 音量下键 = 否，30秒无操作 = 是）"
  START_TIME=$(date +%s)
  while true; do
    NOW_TIME=$(date +%s)
    timeout 1 getevent -lc 1 2>&1 | grep KEY_VOLUME >"$TMPDIR/events"
    if [ $((NOW_TIME - START_TIME)) -gt 29 ]; then
      info "- ⏰ No input detected after 30 seconds, defaulting to keep old configuration." "- ⏰ 30秒无输入，默认保留原配置。"
      extract_keep_config
      break
    elif $(cat $TMPDIR/events | grep -q KEY_VOLUMEUP); then
      extract_keep_config
      break
    elif $(cat $TMPDIR/events | grep -q KEY_VOLUMEDOWN); then
      extract_no_config
      break
    fi
  done
else
  info "- 📦 First time installation, extracting files..." "- 📦 第一次安装，正在解压文件..."
  mkdir -p "$AGH_DIR" "$BIN_DIR" "$SCRIPT_DIR"
  extract_all
fi

info "- 🔐 Setting permissions..." "- 🔐 设置权限..."

chmod +x "$BIN_DIR/AdGuardHome"
chown root:net_raw "$BIN_DIR/AdGuardHome"

chmod +x "$SCRIPT_DIR"/*.sh "$MODPATH"/*.sh

info "- 🎉 Installation completed, please reboot." "- 🎉 安装完成，请重启设备。"
