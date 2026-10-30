# Development and Packaging

[← Back to documentation index](../index.md)

For developers. Regular users should start at the [documentation index](../index.md).

## Layout

```text
.
├── src/                  # module sources (mapped to the ZIP root when packing)
│   ├── bin/              # AdGuardHome.yaml and other runtime files
│   ├── scripts/          # tool.sh / iptables.sh / inotify.sh / debug.sh / base.sh
│   ├── webroot/          # module web UI
│   ├── customize.sh      # installer (keep/backup logic for config files)
│   ├── service.sh        # boot service
│   ├── action.sh         # root manager action button
│   ├── uninstall.sh      # uninstaller
│   ├── settings.conf     # module configuration
│   ├── module.prop       # module metadata
│   └── META-INF/         # installer
├── docs/                 # user documentation (index.md is the entry, zh/ and en/ hold each language)
├── tests/                # offline tests (web UI behaviour, installer arch guard, i18n / version checks)
├── cache/                # packaging cache and output (git-ignored)
├── pack.ps1              # Windows packaging script
├── pack.sh               # Linux / macOS / CI packaging script
├── version.json          # version and update information
└── changelog.md          # current release notes (also used as the Release body)
```

## Local packaging

`pack.ps1` (Windows) and `pack.sh` (Linux / macOS / CI) do the same thing: download and cache the latest AdGuardHome, then pack it together with `src/` into a module ZIP. CI reuses `pack.sh`.

Windows (requires 7-Zip; the script calls `C:\Program Files\7-Zip\7z.exe`):

```powershell
.\pack.ps1
```

Linux / macOS (requires `curl` or `wget`, `tar`, and one of `zip`, `7z`/`7za`, `python3`):

```shell
./pack.sh          # pack arm64 + armv7
./pack.sh arm64    # pack arm64 only
./pack.sh armv7    # pack armv7 only
```

The script then automatically:

1. Creates the `cache` directory if needed.
2. Downloads and caches the latest AdGuardHome (skipped when the cache already has it).
3. Packs AdGuardHome and the contents of `src/` into a ZIP (`cache/AdGuardHomeForRoot_<arch>.zip`).

The resulting ZIP mirrors the layout of `src/`, with the AdGuardHome binary at `bin/AdGuardHome`. Because AdGuardHome is cached, repeated runs do not download it again.

## Tests

Everything in `tests/` runs offline: no device, no network.

| Command | Covers |
| --- | --- |
| `node tests/webui.test.js` | Executes the real `webroot/assets/index.js` against a hand-rolled DOM and a fake KSU bridge: log escaping and highlighting, the log surviving a language switch, the generated save command (appending missing keys, stripping shell metacharacters, rejecting a bad port), the `tool.sh reload` call, and that every id the script looks up exists in the markup |
| `bash tests/arch.test.sh` | The architecture guard lifted verbatim out of `customize.sh`: a package built for another architecture must be rejected, a non-ELF payload must not be judged |
| `python3 tests/check_i18n.py` | `en.json` / `zh.json` carry the same keys and every key the UI references exists |
| `python3 tests/check_version.py` | `version.json` and `module.prop` agree; on a tag build the tag must equal the version |

`node tests/webui.test.js --print-cmd` prints the save command the web UI generates, which can be replayed on a device as is:

```shell
adb push save.sh /data/local/tmp/save.sh
adb shell su -c 'sh /data/local/tmp/save.sh'
```

## CI and releases

[`lint.yml`](../../.github/workflows/lint.yml) runs on every push to `main`, on pull requests and on demand:

1. Shell syntax: every `*.sh` through `bash -n`, plus the device-side scripts under `src/` through `busybox sh -n` (devices run busybox ash / mksh)
2. Front end and data: `node --check`, and every `*.json` parsed
3. The four tests above

Pushing a tag in the form `YYYYMMDD` triggers [`pack.yml`](../../.github/workflows/pack.yml), which only publishes releases:

1. Validates that the tag is an 8-digit date (`YYYYMMDD`)
2. Validates that `version.json`, `module.prop` and the tag agree (a mismatch means users never receive the update)
3. Runs `pack.sh all` to build both architectures
4. Creates a GitHub Release whose body comes from `changelog.md` and whose assets are the two ZIPs in `cache/`

The workflow can also be run manually, in which case it only verifies packaging and produces nothing downloadable. No build artifacts are uploaded to Actions: installable module ZIPs come only from Releases, use `pack.sh` for local builds.

Before releasing, update:

- `version.json`: increment `versionCode`, set `version` to `YYYYMMDD`
- `src/module.prop`: `version` and `versionCode`
- `changelog.md`: keep only the **current release** changes, one Chinese and one English entry

## Commit style

The repository uses [Conventional Commits](https://www.conventionalcommits.org/). Common prefixes: `feat`, `fix`, `docs`, `chore`, `ci`, `refactor`.
