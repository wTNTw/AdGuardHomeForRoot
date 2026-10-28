# 模块控制

[← 返回文档目录](../index.md)

## 方法一：通过模块管理页 (推荐)

进入[模块管理页](configuration.md#2-模块管理页-web-ui)，点击顶部的“启动核心”或“停止核心”按钮即可完成控制；在支持 action 按钮的 root 管理器中，点击模块的“操作/执行”按钮等同于切换状态（启动 ↔ 停止）。

## 方法二：通过配置文件标识 (Shell / 文件管理器)

模块会实时监测 `/data/adb/modules/AdGuardHome` 目录下的 `disable` 文件：

- 存在该文件则禁用模块（停止核心并移除 iptables 规则）
- 不存在该文件则启用模块

你可以使用以下命令进行灵活切换：

```shell
# 停用
touch /data/adb/modules/AdGuardHome/disable
# 启用
rm /data/adb/modules/AdGuardHome/disable
```

## 方法三：直接调用工具脚本

你也可以在 Shell 中直接调用工具脚本：

```shell
/data/adb/agh/scripts/tool.sh start     # 启动
/data/adb/agh/scripts/tool.sh stop      # 停止
/data/adb/agh/scripts/tool.sh toggle    # 切换（运行则停止，停止则启动）
```

## 模块工作原理

本模块可以分为两部分：一部分是 AdGuardHome 本身，它在本地搭建了一个可自定义拦截功能的 DNS 服务器（默认监听 `127.0.0.1:5591`）；另一部分是 iptables 转发规则，它负责将发往本机 53 端口的 DNS 查询（UDP/TCP）重定向到 AdGuardHome 处理。

开机后模块会等待系统启动动画结束，再启动 AdGuardHome；确认 DNS 监听就绪后才会应用 iptables 规则，避免在核心尚未就绪时劫持 53 端口导致设备短时间内无法联网。

## SNI 过滤（自动适配核心）

模块会在每次应用规则时读取 `AdGuardHome.yaml` 中的 `sni_filter` 段来判断当前运行的核心是否支持 SNI 过滤，无需任何额外配置：

- 核心支持（配置里有 `sni_filter`，且它确实已绑定对应的 NFQUEUE 队列）：模块会为 `ports` 中每个端口挂上 `AGH_SNI`/`AGH_SNI6` 链，把新建 TLS 连接的前若干字节送进队列，由核心完成拦截；协议不支持 `connbytes`/`NFQUEUE` 时自动跳过。
- 核心不支持（官方版 AdGuardHome，YAML 里没有 `sni_filter`）：模块只做 DNS 劫持，日志里记一行“跳过 SNI 劫持”，不会报错。
- SNI 规则被外部清空（例如其他模块执行 `iptables -F`、VPN 应用切换）时，守护进程会发现规则缺失并按原样重建。

`check` 只在核心确实占用了队列时才校验 SNI 链，因此换成不支持该特性的核心不会触发无意义的重建循环。
