# SNI 阻断失效：诊断、根因与修复（AdguardHome-Mod + LuCI 面板现场）

> 本文是 2026-10-30 在一台 ImmortalWrt 25.12.1（rockchip/armv8，`192.168.31.2`）
> 上的完整排查记录。核心为 `liuzq2002/AdguardHome-Mod v2026-10-29`，
> 由本面板（luci-app-adguardhome-dashboard）管理，SNI 阻断靠
> `/etc/nftables.d/10-agh-sni.nft` 把 443/8443 送进 NFQUEUE 7。
>
> 目录里的脚本和二进制是那次修复的产物，可复用于同类现场。

## 1. 现象

SNI 阻断（"强力模式"里命中规则就 RST 掉 TLS 连接）运行一段时间后**静默失效**：
DNS 解析、广告过滤一切正常，只是 HTTPS 连接不再被拦；`/etc/init.d/AdGuardHome restart`
后恢复，过一阵又失效。

## 2. 根因（三条缺陷叠加，缺一不可）

日志实证 `/opt/AdGuardHome/crash.log`：

```
14:22:09  recvmsg: no buffer space available                       ← ①
14:22:09  use of closed file / bad file descriptor                ← ③
15:06:08  netlink validate: mismatched sequence in netlink reply   ← ②
（此后过滤器计数器定格在 sni_pkts_received=111637，队列从内核消失）
```

1. **① 收包缓冲溢出（触发）**：核心设了 `MaxPacketLen=16384`、`MaxQueueLen=1024`，
   但**从不设置 `SO_RCVBUF`**，上游依赖 `florianl/go-nfqueue v2.1.0` 也没有该选项
   → netlink socket 用内核默认 `net.core.rmem_default=262144`，约 150~180 个 443 包
   就满。一次页面加载的并发 TLS 握手（或 QUIC 重连）足够把它冲爆 → `ENOBUFS`。
2. **③ 重建竞态**：`reopenQueue()` 先 `nf.Close()` 再立刻 bind 同一个 queue 7，
   旧队列在内核侧尚未 unbind，netlink 应答序号错乱。
3. **② 放弃（致命）**：`watchQueueLoop` 重建失败后只打一条 ERROR 就 `return`，
   不再重试、不再监控；`f.nf = nil`，队列从此不存在。
4. **静默降级**：规则带 `queue flags bypass`，没人监听时 443/8443 全部放行。

实测后果：规则计数器 606406 包，过滤器只收到 111637 个 →
**82% 的 443/8443 流量在失效后直接绕过队列**。

上游 `SNI_HANDOVER.md` §8 自己也确认了这一点（"watcher 重建成功一次：恢复；但如果
重建失败，当前 watcher 不会自动继续重试"），并建议用外部 watchdog。

## 3. 修复方案（三层，全部已落地验证）

### 3.1 源码层：`sni-queue-recovery.patch`（根治）

只改 `internal/snifilter/firewall_linux.go`（+83/−3）：

| 改动 | 解决 |
|---|---|
| `queueReadBuffer = 8 << 20`，`dialQueue()` 里 `nf.Con.SetReadBuffer()`，失败降级 1 MiB 告警 | ① 缓冲：从约 150 包提到数千包，实际受 `maxQueueLen=1024` 约束，`ENOBUFS` 不再可能发生 |
| `watchQueueLoop()` 重建失败改为 1s→2s→…→30s 退避**无限重试**，直到成功或 ctx 取消 | ② 放弃：`mismatched sequence` 之后仍能自愈 |
| 重建成功打 `the nfqueue has been re-registered` | 事后可审计是否发生过自愈 |

构建（交叉编译 arm64，产物已在本目录）：

```sh
git clone https://github.com/liuzq2002/AdguardHome-Mod && cd AdguardHome-Mod
git apply /path/to/sni-queue-recovery.patch
cd client_v2 && npm ci && npm run build-prod && cd ..     # 前端静态资源（//go:embed build）
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath \
  -ldflags "-s -w -X github.com/AdguardTeam/AdGuardHome/internal/version.version=v2026-10-29-mod-sni1 \
            -X github.com/AdguardTeam/AdGuardHome/internal/version.channel=release \
            -X github.com/AdguardTeam/AdGuardHome/internal/version.committime=$(date +%s)" \
  -o AdGuardHome-arm64 .
```

产物：23199904 字节，sha256 `6437b12373b0ac17a1da11e8678109da19d8267b96a07673b1a7e2b2f55cc64f`，
版本串 `v2026-10-29-mod-sni1`（带后缀，面板不会把它当成"可升级"而静默覆盖）。
`go test ./internal/snifilter/` 通过。

### 3.2 防火墙层：`10-agh-sni.nft`（让"拦住"变成"秒断"）

排查中发现的**独立**老问题（修复前后都存在，与补丁无关）：

```
[debug] snifilter: sending the reset segment dst=192.168.31.124:46114 err="operation not permitted"
```

`nft monitor trace` 定位到丢弃点：

```
inet fw4 output rule ct state vmap { invalid : drop, established : accept, related : accept } (verdict drop)
```

注入的伪造 RST 源地址是远端站点，conntrack 里没有对应条目 → `invalid` → 被 fw4 丢掉，
`sendto()` 返回 EPERM。连接照样被拦（ClientHello 已 DROP），但客户端要**卡到 TCP 超时**。

修复（加在同一个 nftables.d 文件里）：

```nft
chain agh_sni_notrack {
	type filter hook output priority -300; policy accept;
	tcp flags & (rst) == rst fib saddr type != local counter notrack
}
```

- `notrack` 在 conntrack（priority −200）之前生效 → untracked → 不再命中 `ct state invalid`
- `fib saddr type != local` 只命中"源地址不是本机"的包；本机进程正常发出的 RST 仍走原判定
- `output` 钩子只处理本机产生的包，LAN 客户端无法借它绕过 forward 链

**踩坑**：写成另一个 base chain 里的 `accept` 无效——nftables 的 base chain 相互独立，
`accept` 只结束当前链，后面的 `inet fw4 output` 照样 drop（实测该链 counters 涨到 50 包，
EPERM 依旧）。必须 `notrack`，或把规则塞进 fw4 的 output 链（但 `fw4 reload` 会覆盖）。

### 3.3 观测层：`agh-sni-watchdog.sh`（兜住内核修不了的情况）

procd 守护，每 5 秒读 `/proc/net/netfilter/nfnetlink_queue`：

- 队列行消失 / `peer_port = 0` / `queue_total ≥ 768` 且 `id_seq` 不动 → 连续 3 次确认（≈15 秒）后重启 AGH
- 10 分钟冷却，避免重启风暴；重启后等 30 秒复验队列绑定
- 顺带检查 nft 链是否还在（`fw4 reload` 丢链也常见），缺了先 `firewall reload`
- `agh-sni-watchdog.sh --once` 可单次体检（退出码 0=正常，1=异常）

仍需保留的原因：callback 卡死、OOM、进程被 kill 这类情况进程内无法自愈。

## 4. 现场验证数据

**SNI A/B（同一 IP、同一端口，只有 SNI 不同）**

| SNI | 目标 | 修复前 | 修复后 |
|---|---|---|---|
| `www.bing.com`（未拦） | 111.206.209.249 | handshake OK 0.13s | handshake OK 0.12s |
| `hm.baidu.com`（拦） | 111.206.209.249 | 卡 5.04s 超时 | **ConnectionResetError 0.04s** |
| `www.bing.com`（未拦） | 153.3.237.72 | handshake OK 0.12s | handshake OK 0.11s |
| `pos.baidu.com`（拦） | 153.3.237.72 | 卡 5.05s 超时 | **ConnectionResetError 0.05s** |

**队列健康**（自补丁核心启动后）

```
queue 7: 7 <pid> 0 2 16384 0 0 <id_seq 持续增长> 1     total=0  dropped=0  user_dropped=0
[error] 行数：0    （无 ENOBUFS / mismatched sequence / bad file descriptor）
```

**其他旁证**

- `enlarged the nfqueue read buffer bytes=8388608` 出现在启动日志（补丁生效）
- `sni_resets_sent` 在 notrack 修复后一分钟内 19 → 91（RST 真的发出去了）
- watchdog 自测（假队列 99）：`sample 1/2 bad → restarting ... because: queue 99 unbound`
- `fw4 print` 含 `include "/etc/nftables.d/*.nft"`，整套生成脚本 `nft -c -f` 校验通过
  → 重启 / `fw4 reload` 后规则会自动恢复

## 5. 目录内容

```
AdGuardHome-arm64         补丁版核心（linux/arm64，静态链接，含前端静态资源）  23 MB
sni-queue-recovery.patch  上游 diff（单文件 +83/-3）
10-agh-sni.nft            含 agh_sni + agh_sni_notrack 两条链的防火墙规则（修复后）
10-agh-sni.nft.orig       同文件修复前版本（回滚用）
agh-sni-watchdog.sh       watchdog（支持 --once）
agh-sni-watchdog.init     procd 服务定义
deploy.sh                 verify / install-core / install-firewall / install-watchdog / rollback
rawrst.go, rawrst-arm64   复现 EPERM 的最小程序（诊断用，1.5 MB）
remote-run.sh             本机调试辅助：把本地脚本 scp 到路由器执行（凭据走环境变量）
```

> `AdGuardHome-arm64` 有 23 MB，若不想让仓库变大，可以删掉它，按 §3.1 的命令自行构建。

## 6. 部署步骤

```sh
# 整个目录拷到路由器
scp -O -r fixes/sni-queue-recovery root@192.168.31.2:/tmp/sni-fix

# 路由器上：
sh /tmp/sni-fix/deploy.sh verify            # 基线体检
sh /tmp/sni-fix/deploy.sh install-core      # 换核心（自动备份 + 失败自动回滚，DNS 中断 5~10 秒）
sh /tmp/sni-fix/deploy.sh install-firewall  # 安装 nft 规则并热加载 notrack 链
sh /tmp/sni-fix/deploy.sh install-watchdog  # 装 watchdog
sh /tmp/sni-fix/deploy.sh verify            # 复验
```

回滚：

```sh
sh /tmp/sni-fix/deploy.sh rollback          # 核心
cp /etc/nftables.d/10-agh-sni.nft.orig /etc/nftables.d/10-agh-sni.nft && fw4 reload
```

## 7. 注意事项

- 面板的「一键升级核心」会用官方发布覆盖补丁版；升级后重跑 `install-core`，或等上游合并补丁。
- 部署后路由器上的落点是：`/opt/AdGuardHome/AdGuardHome`（+ `.bak-<时间戳>` 与 `.sha256`）、
  `/etc/nftables.d/10-agh-sni.nft`、`/usr/bin/agh-sni-watchdog.sh`、`/etc/init.d/agh-sni-watchdog`。
- `net.core.rmem_default` 不必手动调，补丁版自己设置 socket 缓冲。
- `/etc/adguardhome/adguardhome.yaml` 是旧副本，真正生效的是 `/opt/AdGuardHome/AdGuardHome.yaml`
  （本面板的查找顺序 `/opt` 优先，所以没问题；手工改配置时注意别改错文件）。
- 日常复核：

  ```sh
  cat /proc/net/netfilter/nfnetlink_queue                   # queue 7 是否有人绑定
  nft list chain inet fw4 agh_sni_notrack | grep counter     # RST 放行计数是否增长
  grep "sni filter counters" /opt/AdGuardHome/crash.log | tail -1
  /usr/bin/agh-sni-watchdog.sh --once
  ```
