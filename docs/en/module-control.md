# Module Control

[← Back to documentation index](../index.md)

## Option 1: Module web UI (recommended)

Open the [module web UI](configuration.md#2-module-web-ui) and tap "Start core" or "Stop core". In root managers that support the action button, tapping the module's action button toggles the state (start ↔ stop).

A manual "stop" is remembered: the module leaves a marker file at `/data/adb/agh/.stopped`, and the watchdog leaves the core down while it exists (without it the core came back on its own within 60 seconds). Three ways to clear it: tap "Start core", delete the `.stopped` file, or reboot (`service.sh` clears it at boot).

## Option 2: The disable file (shell / file manager)

The module watches the `disable` file in `/data/adb/modules/AdGuardHome`:

- If the file exists, the module is disabled (core stopped, iptables rules removed)
- If the file does not exist, the module is enabled

Use these commands to switch states:

```shell
# disable
touch /data/adb/modules/AdGuardHome/disable
# enable
rm /data/adb/modules/AdGuardHome/disable
```

## Option 3: Call the helper script directly

You can also call the helper script from a shell:

```shell
/data/adb/agh/scripts/tool.sh start     # start
/data/adb/agh/scripts/tool.sh stop      # stop (also records the manual-stop state)
/data/adb/agh/scripts/tool.sh toggle    # toggle (stop if running, start if stopped)
/data/adb/agh/scripts/tool.sh ensure    # repair: bring back a dead core or a lost hijack (what the watchdog runs)
/data/adb/agh/scripts/tool.sh reload    # re-apply the saved settings.conf (what the web UI's "save and apply" runs)
```

Only one state change runs at a time: `start` / `stop` / `reload` queue up (waiting at most one startup window), while `ensure` skips its turn and waits for the next watchdog tick. The lock lives in `/data/adb/agh/.lock`, and a stale lock is taken over automatically.

## How it works

The module has two parts: AdGuardHome itself, which runs a local DNS server with customizable filtering (listening on `127.0.0.1:5591` by default), and the iptables redirect rules, which send DNS queries addressed to port 53 (UDP/TCP) to AdGuardHome.

After boot the module waits for the boot animation to finish, starts AdGuardHome, and applies the iptables rules only once the DNS listener is up, so the device does not lose DNS while the core is still initializing.

Boot goes through `ensure` rather than `start`: a core that survived a userspace restart is adopted as it is, and redirect rules wiped while the module still looked healthy are restored in the same pass instead of waiting for the first watchdog check. The background helpers (inotify watcher and watchdog) are swept before every boot / repeated `service.sh` run and finished off with SIGKILL, so a script blocked in `sleep` cannot survive and pile up as a duplicate.

## SNI filtering (adapted to the running core)

Every time it applies rules, the module reads the `sni_filter` section of `AdGuardHome.yaml` to work out whether the running core supports SNI filtering. No extra configuration is needed:

- Core supports it (`sni_filter` is present and the core really holds the matching NFQUEUE queue): the module attaches `AGH_SNI` / `AGH_SNI6` chains for each port in `ports` and sends the first bytes of every new TLS connection to the queue, where the core drops the connection. If the kernel lacks `connbytes` / `NFQUEUE`, the step is skipped.
- Core does not support it (official AdGuardHome, no `sni_filter` in the YAML): only the DNS redirect is installed and one "skipping SNI hijack" line is logged. Nothing fails.
- If the SNI rules are wiped by something else (`iptables -F` from another module, switching VPN apps, …), the watchdog notices the missing rules and rebuilds them.

`check` verifies the SNI chains only while the core actually holds the queue, so running a core without this feature cannot send the watchdog into a needless rebuild loop.
