#!/bin/sh
# agh-sni-watchdog.sh -- AdGuardHome SNI 队列外部看门狗
#
# 背景：AdguardHome-Mod 的 SNI 过滤依赖 nfqueue。内核丢包后，核心里的重建逻辑
# 只尝试一次，失败就永久放弃监控；此时 nft 规则里的 queue flags bypass 会让
# 443/8443 全部静默放行，SNI 阻断失效但不报错。上游 SNI_HANDOVER.md §8.2 明确
# 建议由外部 watchdog 观察 /proc/net/netfilter/nfnetlink_queue 并重启进程。
#
# 用法：用 procd 守护（见 /etc/init.d/agh-sni-watchdog），
#       或 `agh-sni-watchdog.sh --once` 只体检一次（退出码 0=正常，1=异常）。
set -u

QUEUE_NUM="${QUEUE_NUM:-7}"
INTERVAL="${INTERVAL:-5}"          # 采样间隔（秒）
FAIL_LIMIT="${FAIL_LIMIT:-3}"      # 连续异常多少次才动手
COOLDOWN="${COOLDOWN:-600}"        # 两次重启之间的最短间隔（秒）
STUCK_TOTAL="${STUCK_TOTAL:-768}"  # queue_total 超过它且 id_seq 不动 => 卡死
INIT_SCRIPT="${INIT_SCRIPT:-/etc/init.d/AdGuardHome}"
NFT_CHAIN="${NFT_CHAIN:-inet fw4 agh_sni}"

log() {
	logger -t agh-sni-watchdog -- "$*" 2>/dev/null
	echo "agh-sni-watchdog: $*"
}

# queue_state 输出 "<peer_port> <queue_total> <id_seq>"；队列不存在时输出空。
queue_state() {
	awk -v q="$QUEUE_NUM" '$1 == q { print $2, $3, $8; exit }' \
		/proc/net/netfilter/nfnetlink_queue 2>/dev/null
}

nft_chain_ok() {
	# shellcheck disable=SC2086
	nft list chain $NFT_CHAIN >/dev/null 2>&1
}

# 重启后最多等 30 秒，确认队列真的被重新绑定。
wait_queue() {
	i=0
	while [ "$i" -lt 15 ]; do
		st="$(queue_state)"
		if [ -n "$st" ] && [ "${st%% *}" != "0" ]; then
			return 0
		fi
		sleep 2
		i=$((i + 1))
	done
	return 1
}

if [ "${1:-}" = "--once" ]; then
	st="$(queue_state)"
	if [ -z "$st" ]; then
		echo "queue $QUEUE_NUM: NOT BOUND (SNI 阻断当前失效)"
		nft_chain_ok || echo "nft chain $NFT_CHAIN: MISSING"
		exit 1
	fi
	echo "queue $QUEUE_NUM: peer=$(echo "$st" | cut -d' ' -f1) total=$(echo "$st" | cut -d' ' -f2) id_seq=$(echo "$st" | cut -d' ' -f3)"
	nft_chain_ok || echo "nft chain $NFT_CHAIN: MISSING"
	exit 0
fi

log "started: queue_num=$QUEUE_NUM interval=${INTERVAL}s fail_limit=$FAIL_LIMIT cooldown=${COOLDOWN}s"

fails=0
last_restart=0
last_idseq=""
stuck=0

while :; do
	now=$(date +%s)
	st="$(queue_state)"
	bad=0
	reason=""

	if [ -z "$st" ]; then
		bad=1
		reason="queue $QUEUE_NUM unbound"
	elif [ "${st%% *}" = "0" ]; then
		bad=1
		reason="queue $QUEUE_NUM has no owner"
	else
		total=$(echo "$st" | cut -d' ' -f2)
		idseq=$(echo "$st" | cut -d' ' -f3)
		# 积压长期不降且入队序号不动 => 接收循环卡死
		if [ "$total" -ge "$STUCK_TOTAL" ] && [ "$idseq" = "$last_idseq" ]; then
			stuck=$((stuck + 1))
			if [ "$stuck" -ge "$FAIL_LIMIT" ]; then
				bad=1
				reason="queue $QUEUE_NUM stuck: total=$total id_seq=$idseq"
			fi
		else
			stuck=0
		fi
		last_idseq="$idseq"
	fi

	if [ "$bad" -eq 0 ]; then
		if [ "$fails" -gt 0 ]; then
			log "healthy again, $fails bad sample(s) discarded"
		fi
		fails=0
		sleep "$INTERVAL"
		continue
	fi

	fails=$((fails + 1))
	if [ "$fails" -lt "$FAIL_LIMIT" ]; then
		log "sample $fails/$FAIL_LIMIT bad: $reason"
		sleep "$INTERVAL"
		continue
	fi

	if [ "$((now - last_restart))" -lt "$COOLDOWN" ]; then
		log "still bad ($reason) but a restart happened $((now - last_restart))s ago; waiting for the cooldown"
		fails=0
		sleep "$INTERVAL"
		continue
	fi

	if ! nft_chain_ok; then
		log "nft chain $NFT_CHAIN is missing; reloading the firewall"
		/etc/init.d/firewall reload >/dev/null 2>&1
		sleep 3
		if ! nft_chain_ok; then
			log "ERROR: nft chain $NFT_CHAIN is still missing, check /etc/nftables.d/10-agh-sni.nft"
		fi
	fi

	log "restarting $INIT_SCRIPT because: $reason"
	last_restart=$now
	fails=0
	stuck=0
	$INIT_SCRIPT restart >/dev/null 2>&1

	if wait_queue; then
		log "queue $QUEUE_NUM is bound again: $(queue_state)"
	else
		log "ERROR: queue $QUEUE_NUM is still unbound 30s after the restart; check /opt/AdGuardHome/crash.log"
	fi

	sleep "$INTERVAL"
done
