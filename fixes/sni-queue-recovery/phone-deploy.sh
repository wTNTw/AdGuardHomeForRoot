#!/system/bin/sh
# 在手机上把核心换成补丁版（v2026-10-29-mod-sni1），并做校验
set -u

BIN=/data/adb/agh/bin/AdGuardHome
NEW=/data/local/tmp/AdGuardHome-arm64
STAMP=$(date +%Y%m%d-%H%M%S)
BAK=$BIN.bak-$STAMP
WANT=31b7836f727285b53e2940de7ce191c0db03e7b61ed615e5cd6b88f49fdba97a

echo "== 1) 备份原核心 =="
cp -a "$BIN" "$BAK" && echo "backup -> $BAK"
ls -laZ "$BAK"

echo "== 2) 校验待装二进制 =="
got=$(sha256sum "$NEW" | cut -d' ' -f1)
[ "$got" = "$WANT" ] || { echo "SHA 不符，放弃：$got"; exit 1; }
echo "sha256 OK: $got"

echo "== 3) 同目录暂存 + 修正属主与 SELinux 标签 =="
cp "$NEW" "$BIN.new" || exit 1
chown root:net_raw "$BIN.new"
chmod 755 "$BIN.new"
restorecon "$BIN.new" 2>/dev/null
echo "new:"; ls -laZ "$BIN.new"
echo "old:"; ls -laZ "$BIN"

LABEL_OLD=$(ls -Z "$BIN" | awk '{print $1}')
LABEL_NEW=$(ls -Z "$BIN.new" | awk '{print $1}')
if [ "$LABEL_OLD" != "$LABEL_NEW" ]; then
	echo "标签不同，强制对齐 -> $LABEL_OLD"
	chcon "$LABEL_OLD" "$BIN.new" || echo "WARN: chcon 失败"
fi

echo "== 4) 原子替换（rename，避免 Text file busy） =="
mv -f "$BIN.new" "$BIN" || exit 1
ls -laZ "$BIN"
sha256sum "$BIN"

echo "== 5) 版本 =="
"$BIN" --version

echo "== 6) 重启核心（tool.sh reload） =="
/data/adb/agh/scripts/tool.sh reload
sleep 10

echo "== 7) 状态 =="
ps -A -o PID,RSS,ETIME,NAME 2>/dev/null | grep -i adguard
echo "queue: $(cat /proc/net/netfilter/nfnetlink_queue)"
echo "--- crash.log 尾部 ---"
tail -4 /data/adb/agh/bin/crash.log
