# SNI 阻断失效：诊断、根因与修复（AdguardHome-Mod + LuCI 面板现场）

> 本文是 2026-10-30/31 在一台 ImmortalWrt 25.12.1（rockchip/armv8，`192.168.31.2`）
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

## 3. 修复方案

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

### 3.3 观测层：watchdog —— **分析后已移除**

部署 watchdog 后观察了 **15.9 小时 / 643040 个入队包**：

```
queue 7: 7 <pid> 0 2 16384 0 0 643144 1      total=0  dropped=0  user_dropped=0
counters: received=643040 inspected=67329 names=38213 resets=33451 verdict_errors=0
重建次数（"re-registering the nfqueue"）：0
ENOBUFS（"no buffer space available"）：0
```

补丁把这两个致命路径都堵死之后，watchdog 只剩两种极低概率场景的价值：

| 场景 | 补丁后 | watchdog 价值 |
|---|---|---|
| TLS 突发打爆 socket 缓冲 | 8 MiB 缓冲，实测 15.9h 未触发 | 无 |
| 队列丢失 / 重建失败 | 退避无限重试 | 无 |
| 接收循环卡死（recvmsg 挂住） | 无自愈（但核心会打 `the nfqueue is backed up` 警告） | 有 |
| 进程 OOM / 被杀 | procd `respawn` 自动拉起 | 无 |
| nft 链被外部清空 | `fw4 reload` 会重建 | 有 |

结论：既然目标是"尽量减少常驻依赖"，就把它**从路由器上移除**（零常驻进程、
零额外 init 脚本），只保留脚本本身供手动体检。真出现"卡死"时：

```sh
cp /path/to/agh-sni-watchdog.sh /usr/bin/ && chmod +x /usr/bin/agh-sni-watchdog.sh
/usr/bin/agh-sni-watchdog.sh --once      # 单次体检，不需要守护
```

需要恢复常驻守护（例如上游版本又把自愈改坏）时：

```sh
cp agh-sni-watchdog.sh /usr/bin/agh-sni-watchdog.sh
cp agh-sni-watchdog.init /etc/init.d/agh-sni-watchdog
chmod +x /usr/bin/agh-sni-watchdog.sh /etc/init.d/agh-sni-watchdog
/etc/init.d/agh-sni-watchdog enable && /etc/init.d/agh-sni-watchdog start
```

### 3.4 顺带修掉的报错

| 报错 | 原因 | 处理 |
|---|---|---|
| `WARN the time zone is UTC; set TZ ...`（每次启动一条） | procd 没给 AGH 设 `TZ`，日志全是 UTC，和 syslog（CST）对不上 | `/etc/init.d/AdGuardHome` 加 `procd_set_param env TZ=Asia/Shanghai`（AGH 内置 tzdata，无需 zoneinfo 包），日志时间戳变成本地时间 |
| syslog 被 `queue 99 unbound` 刷了 1138 行 | 自测 watchdog 时用 `&` 起的实例没被杀干净（`INIT_SCRIPT=/bin/true`、`COOLDOWN=0`），一直在自旋重启并报错 | 已 `kill -9` 清除；教训：**自测别再后台起实例**，用 `--once` 或 `timeout` + 事后 `pgrep` 复核 |
| `[error] filtering: updating filter ... EOF`（4 条，24h 周期） | 抓取 GitHub raw 时连接被中断（一次性网络抖动），不是过滤逻辑问题 | 下一轮自动重试；如需稳定可给 AGH 配 `http_proxy` 或换镜像 URL |

## 4. 现场验证数据

**SNI A/B（同一 IP、同一端口，只有 SNI 不同）**

| SNI | 目标 | 修复前 | 修复后 |
|---|---|---|---|
| `www.bing.com`（未拦） | 111.206.209.249 | handshake OK 0.13s | handshake OK 0.11s |
| `hm.baidu.com`（拦） | 111.206.209.249 | 卡 5.04s 超时 | **ConnectionResetError 0.05s** |
| `www.bing.com`（未拦） | 153.3.237.72 | handshake OK 0.12s | handshake OK 0.13s |
| `pos.baidu.com`（拦） | 153.3.237.72 | 卡 5.05s 超时 | **ConnectionResetError 0.05s** |

**旁证**

- 启动日志出现 `enlarged the nfqueue read buffer bytes=8388608`（补丁生效）
- `agh_sni_notrack` 计数器 33441 包 ≈ `sni_resets_sent` 33451 → RST 现在几乎全部真正发出
  （修复前只有零星几次 sendto 成功）
- 移除 watchdog、加 TZ 后重启：`[error]/[warn]` 各 0 条，启动行时间戳已是 CST
- `fw4 print` 含 `include "/etc/nftables.d/*.nft"`，整套生成脚本 `nft -c -f` 校验通过
  → 重启 / `fw4 reload` 后规则自动恢复

## 5. 目录内容

```
AdGuardHome-arm64         补丁版核心（linux/arm64，静态链接，含前端静态资源）  23 MB
sni-queue-recovery.patch  上游 diff（单文件 +83/-3）
10-agh-sni.nft            含 agh_sni + agh_sni_notrack 两条链的防火墙规则（修复后）
10-agh-sni.nft.orig       同文件修复前版本（回滚用）
agh-sni-watchdog.sh       可选：手动体检 / 按需恢复的守护脚本（当前未部署）
agh-sni-watchdog.init     可选：对应 procd 服务定义
deploy.sh                 verify / install-core / install-firewall / patch-tz / install-watchdog(可选) / rollback
phone-deploy.sh           手机端（KernelSU 模块）换核心：备份 + sha 校验 + SELinux 标签对齐 + 原子替换
phone-check.sh            手机端体检：版本 / queue 7 / 计数器 / error 统计 / 配置对齐项
rawrst.go, rawrst-arm64   复现 EPERM 的最小程序（诊断用，1.5 MB）
remote-run.sh             本机调试辅助：把本地脚本 scp 到路由器执行（凭据走环境变量）
README.md                 本文件
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
sh /tmp/sni-fix/deploy.sh verify            # 复验
# install-watchdog 是可选的安全网，见 §3.3 的结论，默认不装
```

回滚：

```sh
sh /tmp/sni-fix/deploy.sh rollback          # 核心
cp /etc/nftables.d/10-agh-sni.nft.orig /etc/nftables.d/10-agh-sni.nft && fw4 reload
```

## 7. 手机侧：AdGuardHome for Root（KernelSU）——同样处理并已对齐

现场：OnePlus 13（PJZ110，Android 16，KernelSU），模块 `AdGuardHome for Root 20261027`，
核心 `/data/adb/agh/bin/AdGuardHome`，队列 7 由 `AGH_SNI` / `AGH_SNI6` 两条 iptables 链送入
（`--connbytes 0:20000 --queue-bypass`，hook 在 `OUTPUT`）。

### 7.1 改动前

- 核心 `v2026-10-29`，sha256 `8baeb11a…` —— 与路由器**打补丁前**的二进制完全一致，隐患同源
- 队列 7 已绑定、`total=0 dropped=0`、`names=4154 resets=460` → 当时还没复发
- `crash.log.1` 里 ENOBUFS 0 次、重建 0 次 → 只是还没赶上那次 TLS 突发
- **一个持续性报错**：`dnsproxy: exchange failed upstream=127.0.0.1:53 … connection refused`，
  每个私网地址的 PTR 查询都报一次，crash.log 累计 3523 条、crash.log.1 里 15969 条。
  根因：`use_private_ptr_resolvers: true` + `local_ptr_upstreams: []` → 退回 Android 的
  系统解析器，而 Android 的 `127.0.0.1:53` 并不监听（netd 不走 localhost）

### 7.2 做的改动

| 动作 | 结果 |
|---|---|
| 备份原核心，同目录暂存新二进制 → `chown root:net_raw` → `restorecon` 对齐 `adb_data_file` 标签 → `mv` 原子替换（避开 ETXTBSY） | 版本与 sha256 与路由器一致 |
| `tool.sh stop` → 改 yaml → `tool.sh start`（模块的 `reload` **只重载 iptables，不重启进程**，容易误判） | queue 7 重新绑定，计数从 0 开始 |
| `use_private_ptr_resolvers: true → false` | PTR 报错从 ~84 条/分钟降到 **0** |
| `clients.runtime_sources.rdns: true → false` | 与路由器一致，省掉无用的 rDNS/PTR 流量 |
| 清理 `/data/local/tmp` 推送的二进制与脚本 | 无残留 |

### 7.3 改动后验证

```
版本 v2026-10-29-mod-sni1        pid 8748, queue 7 → 8748, copy range 16384, total=0
error=0  enobufs=0  re-register=0  in-addr.arpa=0     （改前 126 条 error / 1.5 分钟）
counters: received=1471 inspected=128 names=103 resets=18 verdict_errors=0
DNS: ping www.baidu.com 正常应答
```

### 7.4 手机**不需要**的一项修复

Android 没有 fw4 的 `ct state invalid : drop` 出站规则，注入的伪造 RST 能正常发出
（`sni_resets_sent` 一路增长：旧进程 3 小时 460 次），所以 **不需要 `agh_sni_notrack`**。

### 7.5 两端当前状态对照

| 项 | 路由器 | 手机 |
|---|---|---|
| 核心 | `v2026-10-29-mod-sni1` | 同 |
| 队列 / copy range | 7 / 16384 | 7 / 16384 |
| 入队规则 | nft `prerouting`，`ct original bytes 0-20000` | iptables `OUTPUT` + `AGH_SNI`，`--connbytes 0:20000` |
| RST 放行 | 需要 `agh_sni_notrack`（fw4 invalid drop） | 不需要 |
| `use_private_ptr_resolvers` | false | false（已对齐） |
| `clients.runtime_sources.rdns` | false | false（已对齐） |
| 日志时区 | Asia/Shanghai（init 里加 TZ） | Asia/Shanghai（模块自带） |
| `log.verbose` | false | false |
| 常驻脚本 | 无 | 模块自带 `watchdog.sh`（只修 iptables 劫持，不碰 nfqueue） |

操作：`sh phone-deploy.sh`（换核心）、`sh phone-check.sh`（体检），两者都直接 `adb push`
到 `/data/local/tmp` 后用 `su -c` 跑；回滚把 `AdGuardHome.bak-<时间戳>` 换回去即可。

## 8. 注意事项

- 面板的「一键升级核心」会用官方发布覆盖补丁版；升级后重跑 `install-core`，或等上游合并补丁。
- 部署后路由器上的落点是：`/opt/AdGuardHome/AdGuardHome`（+ `.bak-<时间戳>` 与 `.sha256`）、
  `/etc/nftables.d/10-agh-sni.nft`、`/etc/init.d/AdGuardHome`（多了 `TZ` 环境变量）。
  **没有常驻脚本**。
- `net.core.rmem_default` 不必手动调，补丁版自己设置 socket 缓冲。
- `/etc/adguardhome/adguardhome.yaml` 是旧副本，真正生效的是 `/opt/AdGuardHome/AdGuardHome.yaml`
  （本面板的查找顺序 `/opt` 优先，所以没问题；手工改配置时注意别改错文件）。
- `crash.log` 不轮转（AGH 只是把 stderr 重定向进去），约 30 KB/天，偶尔清理即可。
- 日常复核（三条命令，无需任何脚本）：

  ```sh
  cat /proc/net/netfilter/nfnetlink_queue                  # queue 7 是否有人绑定
  nft list chain inet fw4 agh_sni_notrack | grep counter    # RST 放行计数是否增长
  grep "sni filter counters" /opt/AdGuardHome/crash.log | tail -1
  ```
