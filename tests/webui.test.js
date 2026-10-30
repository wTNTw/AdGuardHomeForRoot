/**
 * Offline harness for src/webroot/assets/index.js.
 *
 * Runs the real file against a hand-rolled DOM and a fake KernelSU/APatch exec
 * bridge, so the shell commands the web UI generates and the markup it renders
 * can be asserted without a phone or a WebView.
 *
 *   node tests/webui.test.js              # run the checks
 *   node tests/webui.test.js --print-cmd  # also print the generated save command
 *
 * The printed command can be replayed verbatim on a device:
 *   adb push <file> /data/local/tmp/save.sh && adb shell su -c 'sh /data/local/tmp/save.sh'
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..');
const SRC = path.join(ROOT, 'src/webroot/assets/index.js');
const HTML = path.join(ROOT, 'src/webroot/index.html');
const code = fs.readFileSync(SRC, 'utf8');
const PRINT_CMD = process.argv.includes('--print-cmd');

const els = {};
function makeEl(id, props = {}) {
  return {
    id,
    type: 'text',
    value: '',
    checked: false,
    textContent: '',
    innerHTML: '',
    className: '',
    placeholder: '',
    scrollTop: 0,
    scrollHeight: 0,
    dataset: {},
    style: {},
    children: [],
    classList: { add() {}, remove() {}, contains: () => false },
    appendChild() {},
    remove() {},
    focus() {},
    setSelectionRange() {},
    addEventListener() {},
    ...props,
  };
}
function byId(id) {
  if (!els[id]) {
    const types = {
      'conf-enable_iptables': 'checkbox',
      'conf-block_ipv6_dns': 'checkbox',
      'conf-redir_port': 'number',
    };
    els[id] = makeEl(id, { type: types[id] || 'text' });
  }
  return els[id];
}

// `refresh()` runs at load and always parses the same ::SPLIT:: layout.
const REFRESH_OUT = [
  '12345',
  '::SPLIT::',
  'enable_iptables=true',
  'block_ipv6_dns=false',
  'redir_port=5591',
  'adg_user=root',
  'adg_group=net_raw',
  '::SPLIT::',
  '127.0.0.1:3000',
  '::SPLIT::',
  'v0.107.79',
].join('\n') + '\n';

const execLog = [];
const domListeners = {};
let nextOut = '';

const sandbox = {};
sandbox.window = sandbox;
sandbox.globalThis = sandbox;
sandbox.console = console;
sandbox.setTimeout = (fn) => { fn(); return 0; };
sandbox.setInterval = () => 0;
sandbox.Date = Date;
sandbox.Math = Math;
sandbox.JSON = JSON;
sandbox.document = {
  body: { className: '' },
  documentElement: { lang: 'en' },
  title: '',
  getElementById: byId,
  createElement: (tag) => makeEl(tag),
  querySelectorAll: () => [],
  addEventListener: (name, fn) => { (domListeners[name] = domListeners[name] || []).push(fn); },
};
sandbox.ksu = {
  exec(cmd, _opts, cbName) {
    execLog.push(cmd);
    let out = nextOut;
    if (!out && cmd.includes('::SPLIT::')) out = REFRESH_OUT;
    nextOut = '';
    // The real bridge calls window[<callback name>] asynchronously.
    setTimeout(() => sandbox.window[cbName](0, out, ''), 0);
  },
};
sandbox.i18n = { t: (key) => `T:${key}` };

vm.createContext(sandbox);
vm.runInContext(code, sandbox, { filename: SRC });

const results = [];
function check(name, cond, detail) {
  results.push({ name, ok: !!cond });
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${detail ? '  ->  ' + detail : ''}`);
}
const tick = () => new Promise((resolve) => setImmediate(resolve));
const fireLanguageChanged = () => (domListeners.languageChanged || []).forEach((fn) => fn());

async function main() {
  // The page must only reference ids the markup really has.
  const htmlFile = fs.readFileSync(HTML, 'utf8');
  const htmlIds = new Set([...htmlFile.matchAll(/\bid="([^"]+)"/g)].map((m) => m[1]));
  const jsIds = new Set(
    [
      ...[...code.matchAll(/\$\('([^']+)'\)/g)],
      ...[...code.matchAll(/getElementById\("([^"]+)"\)/g)],
    ]
      .map((m) => m[1])
      .filter((id) => !id.startsWith('tab-'))   // built from data-tab at runtime
  );
  const missing = [...jsIds].filter((id) => !htmlIds.has(id));
  check('page: every id index.js looks up exists in index.html',
    missing.length === 0, missing.length ? `missing: ${missing.join(', ')}` : `${jsIds.size} ids checked`);

  // --- save handler --------------------------------------------------------
  execLog.length = 0;
  byId('conf-enable_iptables').checked = true;
  byId('conf-block_ipv6_dns').checked = true;
  byId('conf-redir_port').value = '5591';
  byId('conf-adg_user').value = 'root';
  byId('conf-adg_group').value = 'net_raw';
  await byId('btn-save').onclick();
  await tick();

  const saveCmd = execLog.find((c) => c.includes('settings.conf')) || '';
  const reloadCmd = execLog.find((c) => c === '/data/adb/agh/scripts/tool.sh reload');

  check('save: writes settings.conf', !!saveCmd);
  check('save: appends keys missing from a kept-from-old-version config',
    saveCmd.includes('else echo ') && saveCmd.includes('>> /data/adb/agh/settings.conf'));
  check('save: uses a | delimiter so no value can break the expression',
    saveCmd.includes('s|^block_ipv6_dns=.*|block_ipv6_dns=true|'));
  check('save: applies the result through tool.sh reload', !!reloadCmd, reloadCmd);

  execLog.length = 0;
  byId('conf-adg_user').value = 'root"; touch /data/local/tmp/pwned; "';
  await byId('btn-save').onclick();
  await tick();
  const injected = execLog.find((c) => c.includes('settings.conf')) || '';
  const userPart = (injected.match(/\|adg_user=([^|]*)\|/) || [''])[1];
  check('save: strips shell metacharacters from user-controlled fields',
    !injected.includes('touch /data/local/tmp/pwned') && userPart === 'roottouchdatalocaltmppwned',
    userPart);

  execLog.length = 0;
  byId('conf-adg_user').value = 'root';
  byId('conf-redir_port').value = '99999';
  await byId('btn-save').onclick();
  await tick();
  check('save: rejects an out-of-range port without touching anything',
    execLog.length === 0, `exec calls: ${execLog.length}`);
  byId('conf-redir_port').value = '5591';

  // --- log rendering -------------------------------------------------------
  nextOut = [
    '2026-10-30 12:00:00 [info] filter "bad<name>" loaded',
    '<img src=x onerror="alert(1)">',
    '2026-10-30 12:00:01 [error] upstream <b>failed</b>',
  ].join('\n') + '\n';
  await byId('btn-refresh-log').onclick();
  await tick();
  const rendered = byId('log-content').innerHTML;
  check('logs: markup coming from the log is escaped',
    rendered.includes('&lt;img src=x onerror=&quot;alert(1)&quot;&gt;') &&
    !rendered.includes('<img') && !rendered.includes('<b>'),
    rendered.slice(0, 120));
  check('logs: highlighting still works after escaping',
    rendered.includes('<span style="color:#888">2026-10-30 12:00:00</span>') &&
    rendered.includes('<span style="color:#4CAF50">info</span>') &&
    rendered.includes('<span style="color:#F44336">error</span>'));

  const before = byId('log-content').innerHTML;
  fireLanguageChanged();
  check('logs: switching language keeps the loaded log', byId('log-content').innerHTML === before);

  nextOut = '';
  await byId('btn-refresh-log').onclick();
  await tick();
  check('logs: an empty log shows the localized placeholder',
    byId('log-content').textContent === 'T:toast.no_logs', byId('log-content').textContent);
  fireLanguageChanged();
  check('logs: the placeholder survives a language switch',
    byId('log-content').textContent === 'T:toast.no_logs', byId('log-content').textContent);

  if (PRINT_CMD) {
    console.log('\n--- generated save command -------------------------------------');
    console.log(saveCmd);
    console.log('---------------------------------------------------------------');
  }

  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
  process.exit(failed.length ? 1 : 0);
}

main();
