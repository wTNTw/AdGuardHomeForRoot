# 本地改动记录（core 分支）

本分支是 [`liuzq2002/AdguardHome-Mod`](https://github.com/liuzq2002/AdguardHome-Mod)
的镜像，只多出一个本地修复提交；LuCI 面板（`luci-app-adguardhome-dashboard`）
与设备侧部署脚本在同一个仓库的 `main` / `upstream` 分支，不在本分支。

| 项 | 值 |
|---|---|
| 上游基线 | `core-upstream/main` = `77a6852` |
| 本地提交 | `b265c94 fix(snifilter): 提高 nfqueue 收包缓冲，并让队列重建可以重试`（+83/−3，只改 `internal/snifilter/firewall_linux.go`） |
| 标签 | `local/sni-nfqueue-fix` |
| 产物 | `AdGuardHome` arm64，版本串 `v2026-10-29-mod-sni2`，sha256 `31b7836f727285b53e2940de7ce191c0db03e7b61ed615e5cd6b88f49fdba97a` |

## 1. 改了什么

| 改动 | 解决什么 |
|---|---|
| `queueReadBuffer = 8 << 20`，`dialQueue()` 里 `nf.Con.SetReadBuffer()`，失败降级 1 MiB 并告警 | 核心从不设置 netlink socket 的 `SO_RCVBUF`（`go-nfqueue v2.1.0` 也没有该选项），沿用内核默认 256 KiB，约 150~180 个 443 包就会被并发 TLS 握手突发打爆 → `recvmsg: no buffer space available`（ENOBUFS） |
| `watchQueueLoop()` 重建失败后 1s→2s→…→30s 指数退避**无限重试**，直到成功或 ctx 取消 | 原实现只试一次：`mismatched sequence in netlink reply` 后直接 `return`，队列从此不再重建，`f.nf = nil`，SNI 过滤器静默死亡 |
| 重建成功记录 `the nfqueue has been re-registered` | 事后可审计是否发生过自愈 |

配合入队侧（不在本分支）跳过纯 ACK，两侧一起把队列压力降下来：
路由器约 71%、手机约 84% 的包不再进用户态。

## 2. 与 `main` 分支的对应关系

这些改动最初是在 LuCI 仓库里以“补丁文件 + 文档 + 脚本”的形式迭代的，
对应提交 `4c8ca18` … `52b5303`（现仍在 `main` 历史中），文件在
`main:fixes/sni-queue-recovery/`：

| main 中的文件 | 作用 |
|---|---|
| `sni-queue-recovery.patch` | 与本分支 `b265c94` **逐行等价**（86 行 `+/-` 完全一致） |
| `AdGuardHome-arm64` | 上面那个 sha256 的构建产物，两台设备实际运行的就是它 |
| `10-agh-sni.nft` / `10-agh-sni.nft.orig` | 路由器入队规则（纯 ACK 跳过 + notrack 放行注入的 RST） |
| `agh-sni-watchdog.sh` / `.init` | 可选的外部 watchdog（当前未部署） |
| `deploy.sh` / `phone-deploy.sh` / `phone-check.sh` | 路由器与手机的部署/体检脚本 |
| `phone-iptables-ack-skip.patch` | 手机侧 twoone3 模块脚本的改动（目标不是本仓库） |
| `README.md` | 完整排查记录：根因链、nft trace 证据、A/B 数据、上游同步过程 |

## 3. 构建

```sh
git clone https://github.com/liuzq2002/AdguardHome-Mod && cd AdguardHome-Mod
git checkout 77a6852            # 或直接 merge 上游 main
git cherry-pick b265c94         # 或 git apply 上面那份 patch
cd client_v2 && npm ci && npm run build-prod && cd ..   # 前端静态资源（//go:embed build）
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath \
  -ldflags "-s -w \
    -X github.com/AdguardTeam/AdGuardHome/internal/version.version=v2026-10-29-mod-sni2 \
    -X github.com/AdguardTeam/AdGuardHome/internal/version.channel=release \
    -X github.com/AdguardTeam/AdGuardHome/internal/version.committime=$(date +%s)" \
  -o AdGuardHome-arm64 .
```

`go test ./internal/snifilter/` 通过。

## 4. 现场验证（2026-11）

| | 路由器（ImmortalWrt + nftables） | 手机（Android + iptables） |
|---|---|---|
| 核心 | `v2026-10-29-mod-sni2` | 同 |
| queue 7 | 绑定正常、`total=0` | 绑定正常、`total=0` |
| 进入用户态的包占比 | ~29%（2958 纯 ACK 跳过 / 1194 入队） | ~16%（1127 / 216） |
| SNI 计数 | received 2374 / names 233 / resets 124 / verdict_errors 0 | received 179 / names 20 / verdict_errors 0 |
| ENOBUFS / 重建失败 | 0 | 0 |

A/B：未拦截域名握手 0.12~0.13 s 正常；命中规则的 SNI 在 0.04~0.05 s 内被 `ConnectionResetError` 掉。

## 5. 同步上游

```sh
git fetch core-upstream
git merge core-upstream/main      # 冲突只可能出现在 internal/snifilter/firewall_linux.go 附近
git push origin core
```

上游目前（`77a6852`）尚未修这两个问题：`v2026-10-29` 之后对 `internal/snifilter`
只有“删除死 UIDs 代码”和注释改动，所以这份本地修复仍然必需。
