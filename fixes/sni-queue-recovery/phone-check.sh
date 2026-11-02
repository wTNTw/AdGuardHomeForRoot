#!/system/bin/sh
# phone-check.sh -- 手机端 AGH 核心体检（与路由器 deploy.sh verify 口径一致）
# 用法（在手机上，需要 root）：sh phone-check.sh
LOG=/data/adb/agh/bin/crash.log
CFG=/data/adb/agh/bin/AdGuardHome.yaml
BIN=/data/adb/agh/bin/AdGuardHome

echo "=== 版本 / 进程 ==="
"$BIN" --version
ps -A -o PID,RSS,ETIME,NAME 2>/dev/null | grep -i adguard

echo "=== nfqueue（queue 7 是否有人绑定） ==="
cat /proc/net/netfilter/nfnetlink_queue

echo "=== SNI 入队规则 ==="
iptables-save 2>/dev/null | grep -E "AGH_SNI|NFQUEUE" | head -6

echo "=== 计数器（最近 2 条） ==="
grep "sni filter counters" "$LOG" | tail -2

echo "=== 本次启动段：error / ENOBUFS / 重建 ==="
n=$(grep -n "event=start" "$LOG" | tail -1 | cut -d: -f1)
printf 'error=%s  enobufs=%s  re-register=%s  in-addr.arpa=%s\n' \
	"$(tail -n +"${n:-1}" "$LOG" | grep -c '\[error\]')" \
	"$(tail -n +"${n:-1}" "$LOG" | grep -c 'no buffer space')" \
	"$(tail -n +"${n:-1}" "$LOG" | grep -c 're-registering the nfqueue')" \
	"$(tail -n +"${n:-1}" "$LOG" | grep -c 'in-addr.arpa')"

echo "=== 与路由器对齐的配置项 ==="
grep -n -E "^  (use_private_ptr_resolvers|local_ptr_upstreams):" "$CFG"
grep -n -E "^    rdns:" "$CFG"
grep -n -E "^  verbose:" "$CFG"

echo "=== DNS 是否可用 ==="
ping -c 1 -W 2 www.baidu.com 2>&1 | head -2 | tail -1

echo "=== 模块状态 ==="
tail -2 /data/adb/agh/history.log 2>/dev/null
