. /data/adb/agh/settings.conf
. /data/adb/agh/scripts/base.sh

iptables_w="iptables -w 64"
ip6tables_w="ip6tables -w 64"

check_ipv6_nat_support() {
  if ! $ip6tables_w -t nat -L >/dev/null 2>&1; then
    # IPv6 NAT is not supported, we cannot use REDIRECT target
    return 1
  fi

  local redirect_ok=false
  if $ip6tables_w -t nat -A PREROUTING -p tcp --dport 65534 -j REDIRECT --to-port 65534 >/dev/null 2>&1; then
    redirect_ok=true
    $ip6tables_w -t nat -D PREROUTING -p tcp --dport 65534 -j REDIRECT --to-port 65534 >/dev/null 2>&1
  fi

  if $redirect_ok; then
    # IPv6 NAT is supported, we can use REDIRECT target
    return 0
  else
    # IPv6 NAT is not supported, we cannot use REDIRECT target
    return 1
  fi
}

chain_is_complete() {
  # A chain can exist and still be useless: it may have been flushed by another
  # tool, or left half-built by a run that failed midway. "the chain exists" is
  # not proof that port 53 is redirected, so verify the rules themselves.
  local iptables_cmd=$1
  local chain_name=$2

  $iptables_cmd -t nat -C $chain_name -m owner --uid-owner $adg_user --gid-owner $adg_group -j RETURN >/dev/null 2>&1 || return 1
  $iptables_cmd -t nat -C $chain_name -p udp --dport 53 -j REDIRECT --to-ports $redir_port >/dev/null 2>&1 || return 1
  $iptables_cmd -t nat -C $chain_name -p tcp --dport 53 -j REDIRECT --to-ports $redir_port >/dev/null 2>&1 || return 1
  $iptables_cmd -t nat -C OUTPUT -j $chain_name >/dev/null 2>&1 || return 1

  return 0
}

enable_iptables_chain() {
  local iptables_cmd=$1
  local chain_name=$2

  if $iptables_cmd -t nat -L $chain_name >/dev/null 2>&1 && chain_is_complete "$iptables_cmd" "$chain_name"; then
    log "$chain_name chain already exists" "$chain_name 链已经存在"
    return 0
  fi

  if $iptables_cmd -t nat -L $chain_name >/dev/null 2>&1; then
    log "Rebuilding incomplete $chain_name chain" "重建不完整的 $chain_name 链"
    $iptables_cmd -t nat -F $chain_name >/dev/null 2>&1
    $iptables_cmd -t nat -D OUTPUT -j $chain_name >/dev/null 2>&1
  else
    log "Creating $chain_name chain and adding rules" "创建 $chain_name 链并添加规则"
    $iptables_cmd -t nat -N $chain_name || return 1
  fi
  $iptables_cmd -t nat -A $chain_name -m owner --uid-owner $adg_user --gid-owner $adg_group -j RETURN || return 1

  for subnet in $ignore_dest_list; do
    if ! $iptables_cmd -t nat -A $chain_name -d $subnet -j RETURN >/dev/null 2>&1; then
      log "Warning: Failed to add bypass for $subnet (DNS resolution likely failed)" "警告：无法为 $subnet 添加绕过规则（可能由于 DNS 解析失败）"
    fi
  done

  for subnet in $ignore_src_list; do
    if ! $iptables_cmd -t nat -A $chain_name -s $subnet -j RETURN >/dev/null 2>&1; then
      log "Warning: Failed to add bypass for source $subnet" "警告：无法为源 $subnet 添加绕过规则"
    fi
  done

  $iptables_cmd -t nat -A $chain_name -p udp --dport 53 -j REDIRECT --to-ports $redir_port || return 1
  $iptables_cmd -t nat -A $chain_name -p tcp --dport 53 -j REDIRECT --to-ports $redir_port || return 1
  $iptables_cmd -t nat -I OUTPUT -j $chain_name || return 1

  log "Applied iptables rules successfully" "成功应用 iptables 规则"
}

disable_iptables_chain() {
  local iptables_cmd=$1
  local chain_name=$2

  log "Deleting $chain_name chain and rules" "删除 $chain_name 链及规则"
  $iptables_cmd -t nat -D OUTPUT -j $chain_name >/dev/null 2>&1
  $iptables_cmd -t nat -F $chain_name >/dev/null 2>&1
  $iptables_cmd -t nat -X $chain_name >/dev/null 2>&1
  return 0
}

add_block_ipv6_dns() {
  if $ip6tables_w -t filter -L ADGUARD_BLOCK_DNS >/dev/null 2>&1; then
    log "ADGUARD_BLOCK_DNS chain already exists" "ADGUARD_BLOCK_DNS 链已经存在"
    if ! $ip6tables_w -t filter -C OUTPUT -j ADGUARD_BLOCK_DNS >/dev/null 2>&1; then
      $ip6tables_w -t filter -I OUTPUT -j ADGUARD_BLOCK_DNS
    fi
    return 0
  fi

  log "Creating ADGUARD_BLOCK_DNS chain and adding rules" "创建 ADGUARD_BLOCK_DNS 链并添加规则"
  $ip6tables_w -t filter -N ADGUARD_BLOCK_DNS || return 1

  # Reject rather than drop. A silently dropped query leaves the client waiting
  # out its full timeout before retrying over IPv4, which surfaces as random
  # "connected, no internet" stalls on IPv6-native carriers (issue #71). An
  # explicit refusal makes the resolver fall back to IPv4 straight away.
  if ! $ip6tables_w -t filter -A ADGUARD_BLOCK_DNS -p udp --dport 53 -j REJECT --reject-with icmp6-port-unreachable 2>/dev/null; then
    log "REJECT unavailable, falling back to DROP for udp" "REJECT 不可用，udp 回退到 DROP"
    $ip6tables_w -t filter -A ADGUARD_BLOCK_DNS -p udp --dport 53 -j DROP || return 1
  fi
  if ! $ip6tables_w -t filter -A ADGUARD_BLOCK_DNS -p tcp --dport 53 -j REJECT --reject-with tcp-reset 2>/dev/null; then
    log "REJECT unavailable, falling back to DROP for tcp" "REJECT 不可用，tcp 回退到 DROP"
    $ip6tables_w -t filter -A ADGUARD_BLOCK_DNS -p tcp --dport 53 -j DROP || return 1
  fi

  $ip6tables_w -t filter -I OUTPUT -j ADGUARD_BLOCK_DNS || return 1

  log "Applied ipv6 iptables rules successfully" "成功应用 ipv6 iptables 规则"
}

del_block_ipv6_dns() {
  log "Deleting ADGUARD_BLOCK_DNS chain and rules" "删除 ADGUARD_BLOCK_DNS 链及规则"
  $ip6tables_w -t filter -D OUTPUT -j ADGUARD_BLOCK_DNS >/dev/null 2>&1
  $ip6tables_w -t filter -F ADGUARD_BLOCK_DNS >/dev/null 2>&1
  $ip6tables_w -t filter -X ADGUARD_BLOCK_DNS >/dev/null 2>&1
  return 0
}

enable_ipv6_iptables() {
  if ! check_ipv6_nat_support; then
    log "IPv6 NAT is not supported, skipping IPv6 DNS hijack" "IPv6 NAT 不支持，跳过 IPv6 DNS 劫持"
    return 0
  fi

  enable_iptables_chain "$ip6tables_w" "ADGUARD_REDIRECT_DNS6"
}

disable_ipv6_iptables() {
  if ! check_ipv6_nat_support; then
    log "IPv6 NAT is not supported, skipping IPv6 DNS hijack cleanup" "IPv6 NAT 不支持，跳过 IPv6 DNS 劫持清理"
    return 0
  fi

  disable_iptables_chain "$ip6tables_w" "ADGUARD_REDIRECT_DNS6"
}

# ---------------------------------------------------------------------------
# SNI hijack (automatic, no configuration)
#
# Upstream AdGuard Home cannot block by TLS SNI; the liuzq2002 fork can
# (filtering.blocking_mode: strong, driven by the sni_filter section). That fork
# deliberately does not touch netfilter itself - it only opens a named queue and
# waits for somebody else to feed it:
#
#   [info] snifilter: waiting for the packets; the netfilter rules are installed
#          by the operator chain=AGH_SNI queue_num=7
#
# So diverting the packets is the module's job. Instead of adding a knob, detect
# the running core: if its config declares sni_filter AND it has actually bound
# the queue, install the rules; otherwise stay completely out of the way, which
# is exactly today's behaviour for the upstream binary.
# ---------------------------------------------------------------------------

SNI_CHAIN="AGH_SNI"
SNI_CHAIN6="AGH_SNI6"
SNI_YAML="$BIN_DIR/AdGuardHome.yaml"
# How much of each connection is inspected. Only the ClientHello matters, so a
# small window keeps the cost near zero while still covering a fragmented hello.
SNI_CONNBYTES="0:20000"

# Prints "<queue> <port> <port> ..." for the running core, or returns non-zero
# when the core has no SNI filter at all. sni_filter.enabled may legitimately be
# false while strong mode keeps the filter alive, so it is only a hint; the bound
# queue below is the actual proof.
sni_params() {
  [ -r "$SNI_YAML" ] || return 1

  awk '
    /^sni_filter:[[:space:]]*$/ { inf = 1; next }
    /^[a-zA-Z_]/                { inf = 0 }
    !inf                        { next }
    /^[[:space:]]*queue_num:/   { q = $2; next }
    /^[[:space:]]*ports:/       {
      v = $0
      sub(/.*ports:[[:space:]]*/, "", v)
      if (v ~ /\[/) {
        gsub(/[][,]/, " ", v)
        p = p " " v
      }
      next
    }
    /^[[:space:]]*-[[:space:]]*[0-9]+[[:space:]]*$/ { p = p " " $2 }
    END {
      if (q !~ /^[0-9]+$/ || p !~ /[0-9]/) exit 1
      gsub(/[[:space:]]+/, " ", p)
      sub(/^ /, "", p)
      sub(/ $/, "", p)
      print q " " p
    }
  ' "$SNI_YAML" 2>/dev/null
}

# Loads SNI_QUEUE / SNI_PORTS, failing when the core has no SNI filter.
#
# Splitting with "set --" instead of ${var%%...} on purpose: this device's
# /system/bin/sh is mksh, which reads a bare "|" inside a ${...} pattern as an
# extglob alternation, so a "|"-separated value silently collapses. busybox sh
# behaves the other way, which makes it an intermittent bug depending on which
# shell happens to run the script. Word splitting is the same in both.
sni_load() {
  local info
  info=$(sni_params) || return 1
  set -- $info
  SNI_QUEUE=$1
  shift
  SNI_PORTS="$*"
  [ -n "$SNI_QUEUE" ] && [ -n "$SNI_PORTS" ] || return 1
  return 0
}

# Is queue $1 bound by the running AdGuard Home? /proc/net/netfilter/nfnetlink_queue
# holds one line per listener: the queue number, then the netlink port id (which
# is the owning PID). A bound queue is the one signal that cannot lie - it means
# the core really is asking the kernel for those packets.
sni_queue_bound() {
  local pid
  pid=$(cat "$PID_FILE" 2>/dev/null)
  [ -n "$pid" ] || return 1
  [ -r /proc/net/netfilter/nfnetlink_queue ] || return 1
  awk -v q="$1" -v p="$pid" '$1 == q && $2 == p { f = 1 } END { exit !f }' \
    /proc/net/netfilter/nfnetlink_queue 2>/dev/null
}

# The core binds the queue a few moments after it starts, so give it a window
# instead of racing it.
sni_queue_bound_wait() {
  local i=0
  while [ "$i" -lt 6 ]; do
    sni_queue_bound "$1" && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# Can this kernel build the rule at all? Probe inside a throw-away chain that no
# hook can reach, so the test cannot affect a single packet. Cheap insurance for
# ROMs built without xt_connbytes or NFQUEUE, where a silently missing rule would
# otherwise look like "SNI blocking does nothing".
sni_kernel_supports() {
  local cmd=$1 ok=1
  $cmd -t filter -N AGH_SNI_PROBE >/dev/null 2>&1 ||
    $cmd -t filter -F AGH_SNI_PROBE >/dev/null 2>&1
  $cmd -t filter -A AGH_SNI_PROBE -p tcp --dport 443 -m connbytes \
    --connbytes "$SNI_CONNBYTES" --connbytes-dir original --connbytes-mode bytes \
    -j NFQUEUE --queue-num 65000 --queue-bypass >/dev/null 2>&1 && ok=0
  $cmd -t filter -F AGH_SNI_PROBE >/dev/null 2>&1
  $cmd -t filter -X AGH_SNI_PROBE >/dev/null 2>&1
  return $ok
}

sni_chain_is_complete() {
  local cmd=$1 chain=$2 queue=$3
  shift 3
  local port

  for port in "$@"; do
    $cmd -t filter -C "$chain" -p tcp --dport "$port" -m connbytes \
      --connbytes "$SNI_CONNBYTES" --connbytes-dir original --connbytes-mode bytes \
      -j NFQUEUE --queue-num "$queue" --queue-bypass >/dev/null 2>&1 || return 1
    $cmd -t filter -C OUTPUT '!' -o lo -p tcp --dport "$port" -j "$chain" >/dev/null 2>&1 || return 1
  done

  return 0
}

# Removes every OUTPUT jump to $chain by line number. Deleting by rule spec would
# need the exact port list a previous run used, and the list may have changed.
sni_delete_chain_jumps() {
  local cmd=$1 chain=$2 num
  while :; do
    num=$($cmd -t filter -L OUTPUT -n --line-numbers 2>/dev/null |
      awk -v c="$chain" '$2 == c { print $1; exit }')
    [ -n "$num" ] || break
    $cmd -t filter -D OUTPUT "$num" >/dev/null 2>&1 || break
  done
  return 0
}

sni_enable_chain() {
  local cmd=$1 chain=$2 queue=$3
  shift 3
  local port

  if sni_chain_is_complete "$cmd" "$chain" "$queue" "$@"; then
    log "$chain chain already exists" "$chain 链已经存在"
    return 0
  fi

  sni_delete_chain_jumps "$cmd" "$chain"
  $cmd -t filter -F "$chain" >/dev/null 2>&1
  $cmd -t filter -N "$chain" >/dev/null 2>&1

  for port in "$@"; do
    $cmd -t filter -A "$chain" -p tcp --dport "$port" -m connbytes \
      --connbytes "$SNI_CONNBYTES" --connbytes-dir original --connbytes-mode bytes \
      -j NFQUEUE --queue-num "$queue" --queue-bypass || return 1
  done

  # Loopback is left alone so local proxies keep working. One rule per port on
  # purpose: -m multiport is missing on plenty of Android kernels, and a rule
  # that fails to load is invisible - SNI blocking would just look broken.
  #
  # --queue-bypass is not optional either: without it a missing listener turns
  # every TLS connection into a blackhole instead of a no-op.
  for port in "$@"; do
    $cmd -t filter -I OUTPUT 1 '!' -o lo -p tcp --dport "$port" -j "$chain" || return 1
  done

  log "Applied $chain rules (queue $queue)" "成功应用 $chain 规则（队列 $queue）"
}

sni_disable_chain() {
  local cmd=$1 chain=$2
  sni_delete_chain_jumps "$cmd" "$chain"
  $cmd -t filter -F "$chain" >/dev/null 2>&1
  $cmd -t filter -X "$chain" >/dev/null 2>&1
  return 0
}

enable_sni_hijack() {
  local queue ports

  if ! sni_load; then
    # Upstream AdGuard Home. Nothing to divert, and nothing to complain about.
    log "Core has no SNI filter configured, skipping SNI hijack" "内核未配置 SNI 过滤，跳过 SNI 劫持"
    return 0
  fi
  queue=$SNI_QUEUE
  ports=$SNI_PORTS

  if ! sni_queue_bound_wait "$queue"; then
    log "SNI filter configured but queue $queue is not bound, skipping" "配置了 SNI 过滤但内核未绑定队列 $queue，跳过"
    return 0
  fi

  if ! sni_kernel_supports "$iptables_w"; then
    log "Kernel lacks connbytes/NFQUEUE, skipping SNI hijack" "内核缺少 connbytes/NFQUEUE，跳过 SNI 劫持"
    return 0
  fi

  # SNI hijack is a bonus on top of DNS hijacking: it must never be able to take
  # the working DNS setup down with it.
  if ! sni_enable_chain "$iptables_w" "$SNI_CHAIN" "$queue" $ports; then
    log "Failed to apply SNI rules, rolling back" "SNI 规则应用失败，正在回滚"
    sni_disable_chain "$iptables_w" "$SNI_CHAIN"
    return 0
  fi

  if sni_kernel_supports "$ip6tables_w"; then
    sni_enable_chain "$ip6tables_w" "$SNI_CHAIN6" "$queue" $ports ||
      sni_disable_chain "$ip6tables_w" "$SNI_CHAIN6"
  fi

  return 0
}

disable_sni_hijack() {
  # Unconditional: rules left behind after a settings change or an uninstall
  # would silently keep diverting TLS traffic to a queue nobody reads.
  sni_disable_chain "$iptables_w" "$SNI_CHAIN"
  sni_disable_chain "$ip6tables_w" "$SNI_CHAIN6"
  return 0
}

case "$1" in
enable)
  log "Enabling iptables and ipv6 DNS blocking if configured" "启用 iptables 和 ipv6 DNS 阻断（如果已配置）"
  enable_iptables_chain "$iptables_w" "ADGUARD_REDIRECT_DNS" || exit 1

  if [ "$block_ipv6_dns" = true ]; then
    log "IPv6 DNS mode: block (REJECT IPv6 DNS traffic)" "IPv6 DNS 模式: block (拒绝 IPv6 DNS 流量)"
    add_block_ipv6_dns || exit 1
  else
    log "IPv6 DNS mode: hijack (NAT REDIRECT to AdGuard Home)" "IPv6 DNS 模式: hijack (劫持 IPv6 到 AdGuard Home)"
    enable_ipv6_iptables || exit 1
  fi

  # Last, so a slow queue handshake can never delay getting DNS working.
  enable_sni_hijack
  ;;
disable)
  log "Disabling iptables and ipv6 DNS blocking" "禁用 iptables 和 ipv6 DNS 阻断"
  # First, so no TLS packet can be queued while the rest is being torn down.
  disable_sni_hijack

  disable_iptables_chain "$iptables_w" "ADGUARD_REDIRECT_DNS" || exit 1

  del_block_ipv6_dns || exit 1
  disable_ipv6_iptables || exit 1
  ;;
check)
  # Exit 0 only when the DNS hijack is genuinely in place, so callers can tell
  # "the rules are gone" apart from "the resolver is merely running".
  chain_is_complete "$iptables_w" "ADGUARD_REDIRECT_DNS" || exit 1

  # The IPv6 half is verified in whichever shape the module actually applied:
  # blocking when block_ipv6_dns=true, redirecting when it is false. Skipping the
  # redirect case let the watchdog report "hijack is fine" for a chain that had
  # been flushed by another tool, which is the silent IPv6 bypass this whole
  # check exists to catch.
  if [ "$enable_iptables" = true ]; then
    if [ "$block_ipv6_dns" = true ]; then
      $ip6tables_w -t filter -C OUTPUT -j ADGUARD_BLOCK_DNS >/dev/null 2>&1 || exit 1
    elif check_ipv6_nat_support; then
      chain_is_complete "$ip6tables_w" "ADGUARD_REDIRECT_DNS6" || exit 1
    fi
  fi

  # Only verified while the core actually holds the queue. When it does not, the
  # SNI rules are not supposed to exist and the watchdog has nothing to repair -
  # otherwise it would rebuild them forever.
  if sni_load && sni_queue_bound "$SNI_QUEUE"; then
    sni_chain_is_complete "$iptables_w" "$SNI_CHAIN" "$SNI_QUEUE" $SNI_PORTS || exit 1
    if $ip6tables_w -t filter -L "$SNI_CHAIN6" >/dev/null 2>&1; then
      sni_chain_is_complete "$ip6tables_w" "$SNI_CHAIN6" "$SNI_QUEUE" $SNI_PORTS || exit 1
    fi
  fi

  exit 0
  ;;
*)
  echo "Usage: $0 {enable|disable|check}"
  exit 1
  ;;
esac