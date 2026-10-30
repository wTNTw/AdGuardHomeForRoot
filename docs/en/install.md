# Installation and Upgrade

[← Back to documentation index](../index.md)

## Requirements

- A rooted device with [Magisk](https://github.com/topjohnwu/Magisk) / [KernelSU](https://github.com/tiann/KernelSU) / [APatch](https://github.com/bmax121/APatch) installed
- Two builds are provided: arm64 and armv7. **arm64** is recommended: it performs better and is compatible with most modern devices
- The installer verifies that the package can actually run on this device: a wrong-architecture zip is rejected with a message naming the build to download, instead of installing a module whose core cannot start

## Installation

1. Download the zip for your architecture from the [Release](https://github.com/twoone-3/AdGuardHomeForRoot/releases/latest) page
2. Open **Settings -> Network & Internet -> Advanced -> Private DNS** and turn it off (see [FAQ](faq.md))
3. Install the module in your root manager and reboot the device
4. Once the module is running, open <http://127.0.0.1:3000> to access the [AdGuardHome panel](configuration.md#1-adguardhome-panel); the default username and password are both `root`

## Upgrade

Install the new zip over the existing module in your root manager. Because the module keeps your configuration, the installer detects an older installation and asks whether to keep the existing config files:

| Action | Result |
| --- | --- |
| Volume Up, or no input within 30 seconds | **Keep** the existing `settings.conf` and `AdGuardHome.yaml` |
| Volume Down | **Do not keep**: the old files are backed up in place as `settings.conf.bak` and `AdGuardHome.yaml.bak`, then the new defaults are installed |

> Note: the backups sit next to the original files (`/data/adb/agh/` and `/data/adb/agh/bin/`), not in a separate backup directory.

> **armv7 users**: the update check can only name one package, so each architecture has its own update channel (arm64 → `version.json`, armv7 → `version-armv7.json`). An armv7 module installed by an older version points at the arm64 channel, so install `AdGuardHomeForRoot_armv7.zip` by hand once to switch over. Until then the "update" button downloads the arm64 package, which the installer rejects with the name of the build to download instead.

## Uninstall

When the module is removed in your root manager, the uninstall script first stops the core, removes every iptables rule and terminates the background helpers, and only then deletes the `/data/adb/agh` directory, **including the AdGuardHome configuration, filter rules and all logs**. Back it up first if you want to keep them.

> Older versions only deleted the directory, so port `53` stayed redirected to a process that no longer existed and the device gradually lost DNS until the next reboot. No reboot is needed for that anymore.

## Ports

| Port | Purpose | Notes |
| --- | --- | --- |
| `53` | System DNS | Redirected to AdGuardHome by the iptables rules, only when `enable_iptables=true` |
| `5591` | AdGuardHome DNS listener | Defined by `dns.port` in `AdGuardHome.yaml`; must match `redir_port` in `settings.conf` |
| `3000` | AdGuardHome panel | Defined by `http.address` in `AdGuardHome.yaml` |

`5591` and `3000` listen on `127.0.0.1` only by default, so they are not exposed to the local network.
