#!/bin/sh
# deploy.sh -- 把打补丁的 AdGuardHome 核心、SNI watchdog、防火墙规则部署到路由器
#
# 用法（在路由器上执行，需把整个目录一起拷进去，例如 /tmp/sni-fix/）：
#   sh deploy.sh verify            只体检：队列是否绑定、nft 链是否在、核心版本、DNS
#   sh deploy.sh install-core      备份原二进制 → 换成补丁版 → 重启 → 验证（失败自动回滚）
#   sh deploy.sh install-firewall  安装 /etc/nftables.d/10-agh-sni.nft（含 RST notrack 修复）
#   sh deploy.sh patch-tz          给 /etc/init.d/AdGuardHome 加 TZ=Asia/Shanghai（日志不再是 UTC）
#   sh deploy.sh install-watchdog  【可选】装 watchdog（见 README §3.3：日常不需要）
#   sh deploy.sh rollback          回滚核心到最近一次备份
#
# 设计原则：任何一步失败都自动回到工作状态，不会把 DNS 弄挂。
set -eu

QUEUE_NUM="${QUEUE_NUM:-7}"
BIN="/opt/AdGuardHome/AdGuardHome"
BACKUP_DIR="/opt/AdGuardHome"
INIT_SCRIPT="/etc/init.d/AdGuardHome"
NFT_CHAIN="inet fw4 agh_sni"
NFT_NOTRACK="inet fw4 agh_sni_notrack"
NFT_FILE="/etc/nftables.d/10-agh-sni.nft"
EXPECTED_SHA="6437b12373b0ac17a1da11e8678109da19d8267b96a07673b1a7e2b2f55cc64f"
HERE="$(cd "$(dirname "$0")" && pwd)"
NEW_BIN="$HERE/AdGuardHome-arm64"

log() { logger -t agh-sni-deploy -- "$*" 2>/dev/null; echo "[deploy] $*"; }
die() { log "ERROR: $*"; exit 1; }

queue_line() {
	awk -v q="$QUEUE_NUM" '$1 == q { print; exit }' /proc/net/netfilter/nfnetlink_queue 2>/dev/null
}

verify() {
	ok=0

	if [ -x "$BIN" ]; then
		log "core: $("$BIN" --version 2>/dev/null || echo unknown)"
	else
		log "core: MISSING $BIN"
		ok=1
	fi

	if pgrep -f "/opt/AdGuardHome/AdGuardHome" >/dev/null 2>&1; then
		log "process: running (pid $(pgrep -f "/opt/AdGuardHome/AdGuardHome" | head -n1))"
	else
		log "process: NOT RUNNING"
		ok=1
	fi

	line="$(queue_line)"
	if [ -n "$line" ]; then
		log "queue $QUEUE_NUM: $line"
	else
		log "queue $QUEUE_NUM: NOT BOUND -> SNI 阻断当前失效"
		ok=1
	fi

	if nft list chain $NFT_CHAIN >/dev/null 2>&1; then
		log "nft chain $NFT_CHAIN: present"
	else
		log "nft chain $NFT_CHAIN: MISSING"
		ok=1
	fi

	if nft list chain $NFT_NOTRACK >/dev/null 2>&1; then
		log "nft chain $NFT_NOTRACK: present"
	else
		log "nft chain $NFT_NOTRACK: MISSING (被拦连接会卡到超时而不是秒断)"
		ok=1
	fi

	if nslookup www.bing.com 127.0.0.1 >/dev/null 2>&1; then
		log "dns: ok"
	else
		log "dns: FAILED"
		ok=1
	fi

	return "$ok"
}

wait_queue() {
	i=0
	while [ "$i" -lt 20 ]; do
		if [ -n "$(queue_line)" ]; then
			return 0
		fi
		sleep 2
		i=$((i + 1))
	done
	return 1
}

install_core() {
	[ -f "$NEW_BIN" ] || die "找不到 $NEW_BIN"
	[ "$(sha256sum "$NEW_BIN" | cut -d' ' -f1)" = "$EXPECTED_SHA" ] \
		|| die "补丁版核心的 sha256 与预期不符，拒绝部署"

	stamp="$(date +%Y%m%d-%H%M%S)"
	backup="$BACKUP_DIR/AdGuardHome.bak-$stamp"

	log "备份原核心 -> $backup"
	cp -p "$BIN" "$backup"
	sha256sum "$backup" | sed "s|$backup|$(basename "$backup")|" > "$backup.sha256"

	log "替换核心（先拷到同目录再 mv，避免半截文件被 procd 拉起）"
	cp "$NEW_BIN" "$BIN.new"
	chmod 755 "$BIN.new"
	mv "$BIN.new" "$BIN"

	log "重启 AdGuardHome"
	"$INIT_SCRIPT" restart >/dev/null 2>&1 || true

	if wait_queue; then
		log "队列已重新绑定：$(queue_line)"
		verify || log "WARN: 体检有项目不通过，见上"
		return 0
	fi

	log "重启后 40 秒内队列仍未绑定，回滚"
	cp -p "$backup" "$BIN"
	"$INIT_SCRIPT" restart >/dev/null 2>&1 || true
	wait_queue && log "已回滚并恢复绑定" || log "ERROR: 回滚后仍未绑定，请人工检查 /opt/AdGuardHome/crash.log"
	return 1
}

install_firewall() {
	src="$HERE/10-agh-sni.nft"
	[ -f "$src" ] || die "找不到 $src"

	if [ -f "$NFT_FILE" ] && ! cmp -s "$src" "$NFT_FILE"; then
		backup="$NFT_FILE.orig"
		[ -f "$backup" ] || cp -p "$NFT_FILE" "$backup"
		log "已备份原规则 -> $backup"
	fi
	cp "$src" "$NFT_FILE"
	chmod 644 "$NFT_FILE"

	# 离线校验：模拟 fw4 的 include 上下文，只检查不应用
	{
		echo 'table inet fw4 {'
		cat "$NFT_FILE"
		echo '}'
	} > /tmp/agh-nft-check.nft
	if ! nft -c -f /tmp/agh-nft-check.nft; then
		rm -f /tmp/agh-nft-check.nft
		die "规则语法校验失败，未做任何更改"
	fi
	rm -f /tmp/agh-nft-check.nft
	log "规则文件已安装并通过语法校验：$NFT_FILE"

	# 让运行中的规则集也立刻生效（fw4 只在 reload 时才读取 nftables.d）
	if nft list chain $NFT_NOTRACK >/dev/null 2>&1; then
		log "运行中的 $NFT_NOTRACK 已存在，无需热加载"
	else
		nft add chain inet fw4 agh_sni_notrack \
			'{ type filter hook output priority -300 ; policy accept ; }'
		nft add rule inet fw4 agh_sni_notrack \
			'tcp flags & (rst) == rst fib saddr type != local counter notrack'
		log "已热加载 $NFT_NOTRACK"
	fi
}

install_watchdog() {
	log "注意：README §3.3 的结论是日常不需要常驻 watchdog（补丁核心 15.9h 零故障），"
	log "      这条命令只在需要临时加安全网时使用。"
	cp "$HERE/agh-sni-watchdog.sh" /usr/bin/agh-sni-watchdog.sh
	chmod 755 /usr/bin/agh-sni-watchdog.sh
	cp "$HERE/agh-sni-watchdog.init" /etc/init.d/agh-sni-watchdog
	chmod 755 /etc/init.d/agh-sni-watchdog
	/etc/init.d/agh-sni-watchdog enable
	/etc/init.d/agh-sni-watchdog restart
	sleep 2
	log "watchdog: $(/usr/bin/agh-sni-watchdog.sh --once || true)"
}

# patch_tz 给 AGH 的 init 脚本加 TZ，消除每次启动的 UTC 告警，并让 crash.log
# 的时间戳和 syslog（CST）对得上。AGH 内置 tzdata（main.go 里 _ "time/tzdata"），
# 所以不需要装 zoneinfo。可重复执行。
patch_tz() {
	script="/etc/init.d/AdGuardHome"
	[ -f "$script" ] || die "找不到 $script"

	if grep -q 'procd_set_param env TZ=' "$script"; then
		log "$script 已经带 TZ，无需修改"

		return 0
	fi

	cp -p "$script" "$script.bak-$(date +%Y%m%d-%H%M%S)"
	sed -i 's|^\(\s*\)procd_set_param pidfile .*|&\n\1procd_set_param env TZ=Asia/Shanghai|' "$script"

	if ! grep -q 'procd_set_param env TZ=' "$script"; then
		die "写入失败，$script 未改动（备份在同目录 .bak-*）"
	fi

	log "已加入 TZ=Asia/Shanghai，重启后生效：$INIT_SCRIPT restart"
}

rollback() {
	latest="$(ls -1t "$BACKUP_DIR"/AdGuardHome.bak-* 2>/dev/null | grep -v '\.sha256$' | head -n1)"
	[ -n "$latest" ] || die "没有找到备份"
	log "回滚到 $latest"
	cp -p "$latest" "$BIN"
	"$INIT_SCRIPT" restart >/dev/null 2>&1 || true
	wait_queue && log "回滚完成，队列已绑定" || log "ERROR: 回滚后队列仍未绑定"
}

case "${1:-}" in
verify) verify ;;
install-core) install_core ;;
install-firewall) install_firewall ;;
patch-tz) patch_tz ;;
install-watchdog) install_watchdog ;;
rollback) rollback ;;
*) echo "用法: $0 {verify|install-core|install-firewall|patch-tz|install-watchdog|rollback}"; exit 2 ;;
esac
