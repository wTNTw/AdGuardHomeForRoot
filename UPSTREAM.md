# 上游说明（core 分支）

本分支是 AdGuardHome 魔改核心 **liuzq2002/AdguardHome-Mod** 的工作分支：
源码全部来自上游，只额外带了一个本地修复提交和一份改动说明。

| 项 | 值 |
|---|---|
| 上游项目 | <https://github.com/liuzq2002/AdguardHome-Mod> |
| 上游基线 | `77a6852`（`core-upstream/main`） |
| 本分支相对上游 | 2 个提交：`b265c94` 源码修复 + 本文档同批的 `docs: 记录本分支的本地修复来源与构建方式` |
| 修复标签 | `local/sni-nfqueue-fix` → `b265c94` |
| 构建产物 | arm64，版本串 `v2026-10-29-mod-sni2`，sha256 `31b7836f727285b53e2940de7ce191c0db03e7b61ed615e5cd6b88f49fdba97a` |

本地改动内容、根因、构建命令与验证数据见同目录 **[LOCAL_FIXES.md](LOCAL_FIXES.md)**。

## 1. 同步上游

```sh
git fetch core-upstream
git merge core-upstream/main      # 冲突只可能出现在 internal/snifilter/firewall_linux.go 附近
git push origin core
```

远端 `core-upstream` 指向 <https://github.com/liuzq2002/AdguardHome-Mod>；
迁移到新仓库后重新添加即可：

```sh
git remote add core-upstream https://github.com/liuzq2002/AdguardHome-Mod.git
```

## 2. 分支布局与迁移说明

| 分支 | 内容 | 上游 |
|---|---|---|
| `core`（本分支） | AdGuardHome 核心源码 + 本地修复 | `liuzq2002/AdguardHome-Mod` |
| `main` | LuCI 面板 + `fixes/sni-queue-recovery/` | `imonior/luci-app-adguardhome-dashboard` |
| `upstream` | 仅 LuCI 面板，跟随上游 | 同上 |

- `core` 与 `main` **来自两个不同项目，历史互不相关**。迁移到新仓库后保持为两条独立分支：
  不要把 `core` 合并进 `main`（会删掉面板文件），也不要把 `main` 合并进 `core`
- 面板侧的完整排查记录、nft 规则、watchdog 与部署脚本在 `main` 分支的
  `fixes/sni-queue-recovery/`；本分支只放"核心源码 + 精简说明"
- 上游 `77a6852` 至今未修这两个问题（`v2026-10-29` 之后对 `internal/snifilter`
  只有删死代码与注释改动），因此本地修复仍需保留；上游修好后可直接
  `git revert b265c94` 或 `git merge` 时按语义取舍
