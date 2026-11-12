# 上游说明（main 分支）

本分支是 LuCI 面板项目 **luci-app-adguardhome-dashboard** 的工作分支：
主体代码来自上游，本仓库只额外维护了一份 AdGuardHome SNI 修复的现场记录与工具。

| 项 | 值 |
|---|---|
| 上游项目 | <https://github.com/imonior/luci-app-adguardhome-dashboard> |
| 上游基线 | `v2.9.1`（`84276fa`） |
| 本分支 HEAD | `dd76c13` = 上游 `v2.9.1` + 5 个本地提交 + 1 个合并提交 |
| 本地新增目录 | `fixes/sni-queue-recovery/` |

## 1. 本地相对上游多了什么

只有 `fixes/sni-queue-recovery/` 一个目录，不含对面板代码本身的修改：

| 文件 | 作用 |
|---|---|
| `README.md` | SNI 阻断静默失效的完整排查记录（根因链、`nft monitor trace` 证据、A/B 数据、上游同步过程） |
| `sni-queue-recovery.patch` | 核心源码补丁（nfqueue 收包缓冲 8 MiB + 重建退避重试） |
| `AdGuardHome-arm64` | 打好补丁的 arm64 产物，版本串 `v2026-10-29-mod-sni2`，sha256 `31b7836f…` |
| `10-agh-sni.nft` / `.orig` | 路由器入队规则（纯 ACK 跳过 + `notrack` 放行注入的 RST）与修复前版本 |
| `deploy.sh` / `phone-deploy.sh` / `phone-check.sh` | 路由器与手机的部署、体检脚本 |
| `agh-sni-watchdog.sh` / `.init` | 可选的外部 watchdog（当前未部署） |
| `phone-iptables-ack-skip.patch` | 手机当前所用 twoone3 模块脚本的改动 |
| `rawrst.go` / `rawrst-arm64` | 复现 `sendto: operation not permitted` 的最小诊断程序 |

面板本体（`files/`、`scripts/`、`tools/`、`manifest.json`、`README*.md` 等）与上游一致，便于后续合并。

## 2. 同步上游

```sh
git fetch luci-upstream
git merge luci-upstream/main      # 冲突只会出现在面板文件，fixes/ 是本地目录不会冲突
git push origin main
```

远端 `luci-upstream` 指向 <https://github.com/imonior/luci-app-adguardhome-dashboard>；
迁移到新仓库后重新添加即可：

```sh
git remote add luci-upstream https://github.com/imonior/luci-app-adguardhome-dashboard.git
```

## 3. 分支布局与迁移说明

| 分支 | 内容 | 上游 |
|---|---|---|
| `main` | LuCI 面板 + `fixes/sni-queue-recovery/` | `imonior/luci-app-adguardhome-dashboard` |
| `upstream` | 仅 LuCI 面板，跟随上游 | 同上 |
| `core` | **另一个项目**：`liuzq2002/AdguardHome-Mod` 核心源码 + 本地修复 | `liuzq2002/AdguardHome-Mod` |

`main` 与 `core` **历史互不相关**（不同项目），迁移到新仓库后也请保持为两条独立分支：

- 不要把 `core` 合并进 `main`（会把面板文件删掉），也不要把 `main` 合并进 `core`
- 核心补丁若需要出现在 `main`，直接从 `core` 取文件或 cherry-pick，例如
  `git checkout main && git checkout core -- internal/snifilter/`
- `main` 里 `fixes/sni-queue-recovery/README.md` 是这条修复的完整背景文档，
  `core` 里 `LOCAL_FIXES.md` 是核心侧的精简版与构建说明
