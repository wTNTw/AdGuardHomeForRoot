(function () {
    let It = null, rr = 0;
    const ii = "/data/adb/agh";
    const settingsPath = ii + "/settings.conf";
    const binLogPath = ii + "/bin.log";
    const historyLogPath = ii + "/history.log";
    const scriptTool = ii + "/scripts/tool.sh";
    const scriptDebug = ii + "/scripts/debug.sh";
    const debugLogPath = ii + "/debug.log";
    const pidFile = ii + "/bin/agh.pid";
    const yamlPath = ii + "/bin/AdGuardHome.yaml";

    if (typeof ksu < "u" && typeof ksu.exec == "function") { It = ksu; }
    else if (typeof ap < "u" && typeof ap.exec == "function") { It = ap; }

    function exec(cmd) {
        return new Promise((resolve) => {
            if (!It) { resolve({ e: -1, s: "" }); return; }
            const cb = "_mc" + rr++;
            window[cb] = (code, out, err) => {
                delete window[cb];
                resolve({ e: code || 0, s: (out || "").replace(/\r/g, "") });
            };
            It.exec(cmd, "{}", cb);
        });
    }

    const $ = id => document.getElementById(id);
    const t = (key) => window.i18n?.t(key) || key;
    // Log lines end up inside innerHTML for the highlighting below. They carry
    // text this module does not own (filter names, domains, upstream URLs), and
    // this page holds a root exec bridge, so anything unescaped is code.
    const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
    const escapeHtml = s => String(s).replace(/[&<>"']/g, c => ESC[c]);
    let currentStatus = "checking";
    const elements = {
        statusText: $('status-text'),
        statusContainer: $('status-container'),
        pidBadge: $('pid-badge'),
        version: $('agh-version'),
        logContent: $('log-content'),
        linkPanel: $('btn-link-panel'),
        fields: {
            enable_iptables: $('conf-enable_iptables'),
            block_ipv6_dns: $('conf-block_ipv6_dns'),
            redir_port: $('conf-redir_port'),
            adg_user: $('conf-adg_user'),
            adg_group: $('conf-adg_group')
        }
    };

    function showToast(msg) {
        const el = document.createElement('div');
        el.className = 'toast';
        el.textContent = msg;
        $('toast-container').appendChild(el);
        setTimeout(() => el.remove(), 3000);
    }

    async function refresh() {
        const marker = "::SPLIT::";
        // The version only changes with a module update, which reloads this page,
        // so asking the binary again every 5s was a pointless fork+exec. The value
        // is interpolated back into a shell command, so keep it to version-ish
        // characters only.
        const versionCmd = window._aghVersion
            ? `echo "${window._aghVersion}"`
            : `/data/adb/agh/bin/AdGuardHome --version | head -1 | sed 's/.*version //'`;
        const cmd = `
            [ -f ${pidFile} ] && cat ${pidFile} || echo ""; echo "${marker}";
            cat ${settingsPath} 2>/dev/null; echo "${marker}";
            grep -m1 "address:" ${yamlPath} | sed 's/.*address: *//'; echo "${marker}";
            ${versionCmd}
        `;
        const res = await exec(cmd);
        const parts = res.s.split(marker).map(p => p.trim());

        const pid = parts[0];
        const isRunning = pid && /^\d+$/.test(pid);
        document.body.className = isRunning ? 'running' : 'stopped';
        currentStatus = isRunning ? "running" : "stopped";
        elements.statusText.textContent = t(`status.${currentStatus}`);
        if (isRunning) {
            elements.pidBadge.textContent = "PID: " + pid;
            elements.pidBadge.classList.remove('hidden');
        } else {
            elements.pidBadge.classList.add('hidden');
        }

        if (!window._loaded) {
            const conf = {};
            parts[1].split('\n').forEach(l => {
                const kv = l.split('=');
                if (kv.length === 2) conf[kv[0].trim()] = kv[1].trim();
            });
            for (let k in elements.fields) {
                const el = elements.fields[k];
                if (el.type === 'checkbox') el.checked = conf[k] === 'true';
                else el.value = conf[k] || "";
            }
            window._loaded = true;
        }

        window._webAddr = parts[2] || "127.0.0.1:3000";
        const version = (parts[3] || "").replace(/[^0-9A-Za-z.+\-]/g, "");
        if (version) window._aghVersion = version;
        elements.version.textContent = (version || "...");
    }

    $('btn-start').onclick = async () => {
        showToast(t("toast.starting"));
        await exec(`${scriptTool} start`);
        refresh();
    };

    $('btn-stop').onclick = async () => {
        showToast(t("toast.stopping"));
        await exec(`${scriptTool} stop`);
        refresh();
    };

    $('btn-save').onclick = async () => {
        const port = String(elements.fields.redir_port.value || "").trim();
        if (!/^\d+$/.test(port) || +port < 1 || +port > 65535) {
            showToast(t("toast.bad_port"));
            return;
        }

        let cmd = "";
        for (let k in elements.fields) {
            const el = elements.fields[k];
            // These values are interpolated into a double-quoted shell string, so
            // no quote, slash or space may survive: a stray one would break the
            // whole update and leave a half-written settings.conf behind.
            const v = (el.type === 'checkbox' ? String(el.checked) : String(el.value).trim())
                .replace(/[^A-Za-z0-9_.:-]/g, '');
            // An upgraded module keeps the user's old settings.conf, so a key
            // added in a later version can be missing entirely and a bare sed
            // would silently do nothing. Append it instead.
            cmd += `if grep -q "^${k}=" ${settingsPath}; then ` +
                `sed -i "s|^${k}=.*|${k}=${v}|" ${settingsPath}; ` +
                `else echo "${k}=${v}" >> ${settingsPath}; fi; `;
        }
        await exec(cmd);

        // Actually apply: the button says "save and apply", and rewriting the file
        // alone left iptables running on the previous port/user/mode.
        await exec(`${scriptTool} reload`);

        // Re-read from disk so the panel shows what was really stored.
        window._loaded = false;
        showToast(t("toast.saved"));
        refresh();
    };

    elements.linkPanel.onclick = () => {
        let addr = window._webAddr || "127.0.0.1:3000";
        if (addr.startsWith(":")) addr = "127.0.0.1" + addr;
        if (addr.startsWith("0.0.0.0")) addr = addr.replace("0.0.0.0", "127.0.0.1");
        window.open(`http://${addr}`, '_blank');
    };

    document.querySelectorAll('[data-tab]').forEach(b => {
        b.onclick = () => {
            document.querySelectorAll('.tab-btn, .tab-content').forEach(el => el.classList.remove('active'));
            b.classList.add('active');
            $('tab-' + b.dataset.tab).classList.add('active');
            if (b.dataset.tab === 'logs') loadLog();
            if (b.dataset.tab === 'password') loadYamlUser();
        };
    });

    let logType = 'bin';
    let logRaw = "";        // last loaded text, kept so a language switch cannot wipe the view
    async function loadLog() {
        elements.logContent.textContent = t("toast.loading");
        const path = logType === 'bin' ? binLogPath : historyLogPath;
        const res = await exec(`tail -n 100 ${path}`);
        logRaw = res.s || "";
        if (!logRaw) {
            elements.logContent.textContent = t("toast.no_logs");
            return;
        }

        // Apply simple highlighting. Every line is escaped first: the regexes below
        // only look for timestamps, level tags and status emoji, so nothing they
        // add is affected, while anything the log itself contains stays text.
        const lines = logRaw.split('\n').map(raw => {
            if (!raw.trim()) return "";
            let line = escapeHtml(raw);
            // Highlight Timestamps
            line = line.replace(/^(\d{4}[-/]\d{2}[-/]\d{2}\s\d{2}:\d{2}:\d{2}(\.\d+)?)/, '<span style="color:#888">$1</span>');
            // Highlight Levels
            line = line.replace(/\[(info|INFO|debug|DEBUG)\]/, '[<span style="color:#4CAF50">$1</span>]');
            line = line.replace(/\[(warn|WARN|warning|WARNING)\]/, '[<span style="color:#FFC107">$1</span>]');
            line = line.replace(/\[(error|ERROR|fatal|FATAL)\]/, '[<span style="color:#F44336">$1</span>]');
            // Status icons in history log
            line = line.replace(/(🟢|🔴|🧹|LOG)/g, '<span style="filter:drop-shadow(0 0 2px rgba(255,255,255,0.3))">$1</span>');
            return `<div>${line}</div>`;
        });

        elements.logContent.innerHTML = lines.join('');
        elements.logContent.scrollTop = elements.logContent.scrollHeight;
    }

    document.querySelectorAll('[data-log]').forEach(b => {
        b.onclick = () => {
            document.querySelectorAll('[data-log]').forEach(el => el.classList.remove('active'));
            b.classList.add('active');
            logType = b.dataset.log;
            loadLog();
        };
    });

    $('btn-refresh-log').onclick = loadLog;

    $('btn-debug').onclick = async () => {
        showToast(t("toast.generating"));
        await exec(`${scriptDebug}`);
        showToast(`${t("toast.generated")} ${debugLogPath}`);
    };

    $('btn-open-debug').onclick = async () => {
        // /data/adb is root-only and lives outside primary storage, so the old
        // file:// URI could never be opened and the content:// fallback pointed at
        // a path that does not exist (issue #75). Copy it somewhere a viewer can
        // read, then open that copy and say where it is either way.
        const sharePath = "/sdcard/Download/agh-debug.log";
        await exec(`cp -f ${debugLogPath} ${sharePath} && chmod 644 ${sharePath}`);
        await exec(`am start -a android.intent.action.VIEW -d "content://com.android.externalstorage.documents/document/primary%3ADownload%2Fagh-debug.log" -t "text/plain" -f 0x1 >/dev/null 2>&1`);
        showToast(`${t("toast.opened_copy")} ${sharePath}`);
    };

    // ==================== 密码计算 (AdGuardHome.yaml · bcrypt) ====================

    const pwEl = {
        user: $('pw-user'),
        plain: $('pw-plain'),
        confirm: $('pw-confirm'),
        cost: $('pw-cost'),
        result: $('pw-result'),
        status: $('pw-status'),
        generate: $('btn-pw-generate'),
        clear: $('btn-pw-clear'),
        copy: $('btn-pw-copy'),
        apply: $('btn-pw-apply')
    };

    // bcrypt 哈希形如 $2b$12$<22 字符盐><31 字符摘要>
    const HASH_RE = /^\$2[abxy]\$[0-9]{2}\$[./A-Za-z0-9]{53}$/;
    let pwBusy = false;
    let pwApplyArmed = 0;

    function setPwStatus(msg) {
        pwEl.status.textContent = msg || '';
    }

    async function readYamlLines() {
        const res = await exec(`cat ${yamlPath}`);
        if (!res.s) return null;
        return res.s.split('\n');
    }

    /** users 段的行号范围（左闭右开，不含 users: 自身与下一段的起始行） */
    function usersRange(lines) {
        let start = -1;
        for (let i = 0; i < lines.length; i++) {
            if (/^users:[ \t]*$/.test(lines[i])) { start = i + 1; break; }
        }
        if (start < 0) return null;

        let end = lines.length;
        for (let i = start; i < lines.length; i++) {
            if (/^[^\s#]/.test(lines[i])) { end = i; break; }
        }
        return { start: start, end: end };
    }

    /**
     * 列出 users 段中的所有用户
     * nameLine / pwLine 为 1 基行号；pwLine 为 -1 表示该条目没有 password 行
     */
    function listUsers(lines) {
        const range = usersRange(lines);
        if (!range) return [];

        const users = [];
        let entry = -1;
        for (let i = range.start; i <= range.end; i++) {
            const isEntry = i < range.end && /^\s*-\s*name:/.test(lines[i]);
            if (!isEntry && i !== range.end) continue;

            if (entry >= 0) {
                const m = /^\s*-\s*name:\s*(.+?)\s*$/.exec(lines[entry]);
                if (m) {
                    let pwLine = -1;
                    for (let j = entry + 1; j < i; j++) {
                        if (/^\s*password:/.test(lines[j])) { pwLine = j + 1; break; }
                    }
                    users.push({
                        name: m[1].replace(/^["']|["']$/g, ''),
                        nameLine: entry + 1,
                        pwLine: pwLine
                    });
                }
            }
            entry = i;
        }
        return users;
    }

    /** 切入密码页时，用配置文件里的用户名预填输入框 */
    async function loadYamlUser() {
        if (pwEl.user.value) return;
        const lines = await readYamlLines();
        const users = lines ? listUsers(lines) : [];
        pwEl.user.value = users.length ? users[0].name : 'root';
    }

    async function generatePwHash() {
        if (pwBusy) return;
        if (!window.bcrypt) { showToast(t('toast.pw_no_lib')); return; }

        const plain = pwEl.plain.value;
        if (!plain) { showToast(t('toast.pw_empty')); return; }
        if (plain !== pwEl.confirm.value) { showToast(t('toast.pw_mismatch')); return; }

        const cost = parseInt(pwEl.cost.value, 10);
        if (!(cost >= window.bcrypt.MIN_COST && cost <= window.bcrypt.MAX_COST)) {
            showToast(`${t('toast.pw_cost')} ${window.bcrypt.MIN_COST}-${window.bcrypt.MAX_COST}`);
            return;
        }

        pwBusy = true;
        pwEl.generate.disabled = true;
        pwEl.result.value = '';
        setPwStatus(t('toast.pw_computing'));
        const started = Date.now();
        try {
            pwEl.result.value = await window.bcrypt.hash(plain, cost, (progress) => {
                setPwStatus(`${t('toast.pw_computing')} ${Math.round(progress * 100)}%`);
            });
            setPwStatus(`${t('toast.pw_done')} (${((Date.now() - started) / 1000).toFixed(2)}s)`);
            showToast(t('toast.pw_done'));
        } catch (err) {
            setPwStatus('');
            showToast(err && err.message === 'BCRYPT_PASSWORD_TOO_LONG'
                ? t('toast.pw_too_long')
                : t('toast.pw_fail'));
        } finally {
            pwBusy = false;
            pwEl.generate.disabled = false;
        }
    }

    async function copyPwHash() {
        const hash = pwEl.result.value;
        if (!hash) { showToast(t('toast.pw_empty')); return; }

        try {
            if (navigator.clipboard && navigator.clipboard.writeText) {
                await navigator.clipboard.writeText(hash);
                showToast(t('toast.pw_copied'));
                return;
            }
        } catch (err) {
            // 剪贴板 API 不可用（非安全上下文）时回退到 execCommand
        }

        pwEl.result.focus();
        pwEl.result.setSelectionRange(0, hash.length);
        let ok = false;
        try { ok = document.execCommand('copy'); } catch (err) { ok = false; }
        showToast(ok ? t('toast.pw_copied') : t('toast.pw_copy_fail'));
    }

    /** 把哈希写回 AdGuardHome.yaml 中该用户的 password 行 */
    async function applyPwHash() {
        const hash = pwEl.result.value.trim();
        const user = pwEl.user.value.trim();
        if (!HASH_RE.test(hash)) { showToast(t('toast.pw_empty')); return; }
        if (!user) { showToast(t('toast.pw_user')); return; }

        const lines = await readYamlLines();
        if (!lines) { showToast(t('toast.pw_yaml_read')); return; }

        const entry = listUsers(lines).find((u) => u.name === user);
        if (!entry) { showToast(t('toast.pw_user_missing')); return; }
        if (entry.pwLine < 0) { showToast(t('toast.pw_no_field')); return; }

        // 属于危险操作：5 秒内连续点击两次才会真正写入
        if (Date.now() - pwApplyArmed > 5000) {
            pwApplyArmed = Date.now();
            setPwStatus(t('toast.pw_confirm'));
            showToast(t('toast.pw_confirm'));
            return;
        }
        pwApplyArmed = 0;

        // 单引号包 sed 脚本：bcrypt 哈希里的 $ 在双引号里会被 shell 当变量展开，
        // 必须用单引号才能原样写入；哈希只含 ./A-Za-z0-9，不会破坏 sed 语法
        const indent = (/^\s*/.exec(lines[entry.pwLine - 1]) || [''])[0];
        const newLine = indent + 'password: ' + hash;

        await exec(`cp -f '${yamlPath}' '${yamlPath}.bak'`);
        const res = await exec(`sed -i '${entry.pwLine}s|.*|${newLine}|' '${yamlPath}'`);
        const written = res.e === 0
            ? (await exec(`sed -n '${entry.pwLine}p' '${yamlPath}'`)).s.trim()
            : '';

        if (written !== newLine.trim()) {
            setPwStatus('');
            showToast(t('toast.pw_apply_fail'));
            return;
        }
        setPwStatus(`${t('toast.pw_applied')} · ${t('toast.pw_restart')}`);
        showToast(t('toast.pw_applied'));
    }

    pwEl.generate.onclick = generatePwHash;
    pwEl.copy.onclick = copyPwHash;
    pwEl.apply.onclick = applyPwHash;
    pwEl.clear.onclick = () => {
        pwEl.plain.value = '';
        pwEl.confirm.value = '';
        pwEl.result.value = '';
        pwEl.cost.value = window.bcrypt ? window.bcrypt.DEFAULT_COST : 12;
        pwApplyArmed = 0;
        setPwStatus('');
    };

    document.addEventListener("languageChanged", () => {
        if (currentStatus === "running" || currentStatus === "stopped") {
            elements.statusText.textContent = t(`status.${currentStatus}`);
        }

        // #log-content no longer carries data-i18n, so translatePage leaves loaded
        // logs alone; only the two placeholder states need a new language.
        if (!logRaw) {
            elements.logContent.textContent = elements.logContent.textContent === t("toast.no_logs")
                ? t("toast.no_logs")
                : t("logs.waiting");
        }
    });

    if (It) {
        refresh();
        setInterval(refresh, 5000);
    } else {
        elements.statusText.textContent = t("toast.open_manager");
    }
})();
