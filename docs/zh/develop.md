# 开发与打包

[← 返回文档目录](../index.md)

面向开发者的说明。普通用户请从[文档目录](../index.md)开始阅读。

## 目录结构

```text
.
├── src/                  # 模块源码（打包时映射到 ZIP 根目录）
│   ├── bin/              # AdGuardHome.yaml 与其它运行所需文件
│   ├── scripts/          # tool.sh / iptables.sh / inotify.sh / debug.sh / base.sh
│   ├── webroot/          # 模块管理页 (Web UI)
│   ├── customize.sh      # 安装脚本（含保留/备份配置逻辑）
│   ├── service.sh        # 开机启动
│   ├── action.sh         # root 管理器 action 按钮
│   ├── uninstall.sh      # 卸载脚本
│   ├── settings.conf     # 模块配置
│   ├── module.prop       # 模块信息
│   └── META-INF/         # 安装器
├── docs/                 # 用户文档（index.md 为索引，zh/ 与 en/ 分别为中英文）
├── tests/                # 离线测试（Web UI 行为、安装器架构校验、i18n / 版本一致性）
├── cache/                # 打包缓存与输出（已被 .gitignore 忽略）
├── pack.ps1              # Windows 打包脚本
├── pack.sh               # Linux / macOS / CI 打包脚本
├── version.json          # 版本与更新信息
└── changelog.md          # 当前版本的更新说明（同时作为 Release 正文）
```

## 本地打包

`pack.ps1`（Windows）与 `pack.sh`（Linux / macOS / CI）逻辑一致：下载并缓存最新版 AdGuardHome，与 `src/` 一起打包成模块 ZIP，CI 打包同样复用 `pack.sh`。

Windows（需要已安装 7-Zip，脚本会调用 `C:\Program Files\7-Zip\7z.exe`）：

```powershell
.\pack.ps1
```

Linux / macOS（需要 `curl` 或 `wget`、`tar`，以及 `zip`、`7z`/`7za`、`python3` 三者之一）：

```shell
./pack.sh          # 打包 arm64 + armv7
./pack.sh arm64    # 仅打包 arm64
./pack.sh armv7    # 仅打包 armv7
```

运行脚本后会自动完成：

1. 创建 `cache` 目录（如果尚未存在）。
2. 下载并缓存最新版本的 AdGuardHome（仅在 `cache` 目录中未找到缓存时执行下载）。
3. 将 AdGuardHome 与 `src/` 的内容打包成 ZIP（输出至 `cache/AdGuardHomeForRoot_<arch>.zip`）。

产物 ZIP 的结构与 `src/` 一致，AdGuardHome 二进制位于 `bin/AdGuardHome`。脚本具有缓存机制：如果 `cache` 目录中已存在 AdGuardHome 的缓存版本，则不会重复下载，从而节省时间和带宽。

打包时还会给每个架构写入自己的更新通道：arm64 打包内的 `module.prop` 指向 `version.json`，armv7 指向 `version-armv7.json`（一个 JSON 只能写一个 `zipUrl`）。`pack.sh` 与 `pack.ps1` 都会做这一步，并在写入失败时直接报错而不是默默产出错包。

## 测试

`tests/` 下的检查全部离线运行，不需要设备与网络：

| 命令 | 覆盖内容 |
| --- | --- |
| `node tests/webui.test.js` | 用仿 DOM + 假 KSU 桥直接执行真实 `webroot/assets/index.js`：日志转义与高亮、语言切换不清空日志、保存命令的生成（缺键追加、元字符过滤、端口校验）、`tool.sh reload` 调用、元素 id 与 HTML 的交叉校验 |
| `bash tests/arch.test.sh` | 从 `customize.sh` 原样抽出的架构校验函数：错架构安装包必须被拒，非 ELF 载荷不得误判 |
| `python3 tests/check_i18n.py` | `en.json` / `zh.json` 键集合一致，且界面引用到的键都存在 |
| `python3 tests/check_version.py` | `version.json` 与 `module.prop` 一致；在 tag 构建下还要求 tag 等于版本号 |

`node tests/webui.test.js --print-cmd` 会把 Web UI 生成的保存命令打印出来，可直接 push 到设备上复现：

```shell
adb push save.sh /data/local/tmp/save.sh
adb shell su -c 'sh /data/local/tmp/save.sh'
```

## CI 与发版

[`lint.yml`](../../.github/workflows/lint.yml) 在每个 push（`main`）、PR 与手动触发时运行：

1. Shell 语法：全部 `*.sh` 走 `bash -n`，设备侧脚本（`src/`）额外走 `busybox sh -n`（设备实际用的是 busybox ash / mksh）
2. 前端与数据文件：`node --check`、`*.json` 逐个解析
3. 上面四个测试

推送形如 `YYYYMMDD` 的 tag 会触发 [`pack.yml`](../../.github/workflows/pack.yml)，该 workflow 只负责发版：

1. 校验 tag 必须为 8 位日期（`YYYYMMDD`）
2. 校验 `version.json`、`module.prop`、tag 三者一致（不一致会让用户的更新检查永远收不到新版）
3. 调用 `pack.sh all` 打包两个架构
4. 创建 GitHub Release，正文取自 `changelog.md`，附件为 `cache/` 下的两个 ZIP

workflow 也可手动触发，此时只验证打包、不产出可下载文件。Actions 页面不上传构建产物，可安装的模块包只从 Releases 获取，本地自测请用 `pack.sh`。

发版前请同步更新以下文件：

- `version.json`（arm64）与 `version-armv7.json`（armv7）：`versionCode` 递增，`version` 使用 `YYYYMMDD`，两个文件的 `zipUrl` 分别指向对应架构的 ZIP
- `src/module.prop`：`version` 与 `versionCode`
- `changelog.md`：仅保留**当前版本**的变更，中英各一段

`tests/check_version.py` 会校验这四个文件与 tag 是否一致，`pack.yml` 在打包前也会跑一遍，因此漏改不会变成一个「用户永远收不到更新」的版本。

## 提交规范

仓库使用 [Conventional Commits](https://www.conventionalcommits.org/)，常用前缀：`feat`、`fix`、`docs`、`chore`、`ci`、`refactor`。
