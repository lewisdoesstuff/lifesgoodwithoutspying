// lifesgoodwithoutspying frontend.
'use strict';

(function () {
    var APP_ID = 'ooo.lew.lifesgoodwithoutspying';
    var HBC = 'luna://org.webosbrew.hbchannel.service';
    var appEl = document.getElementById('app');
    var consoleEl = document.getElementById('console');
    var out = document.getElementById('out');
    var enabled = false;
    var dirty = false;
    var restoreFocus = null;
    function errmsg(e) {
        return e instanceof Error ? e.message : String(e);
    }
    function showConsole(show) {
        consoleEl.hidden = !show;
        var layers = document.getElementById('layers');
        if (layers)
            layers.hidden = show;
        var b = document.getElementById('btn-log');
        if (b)
            b.textContent = show ? 'Hide log' : 'Show log';
    }
    function log(line) {
        if (!line && line !== 0)
            return;
        var t = new Date().toLocaleTimeString();
        out.textContent = (out.textContent || '') + '[' + t + '] ' + line + '\n';
        consoleEl.scrollTop = consoleEl.scrollHeight;
    }
    // luna call, returns a promise that resolves to the parsed JSON result
    function luna(url, params) {
        return new Promise(function (resolve, reject) {
            var Bridge = window.PalmServiceBridge;
            if (typeof Bridge === 'function') {
                var bridge = new Bridge();
                bridge.onservicecallback = function (msg) {
                    var data;
                    try {
                        data = JSON.parse(msg);
                    }
                    catch (e) {
                        data = { raw: msg };
                    }
                    if (data && data.returnValue === false) {
                        reject(new Error(data.errorText || 'Luna call failed'));
                    }
                    else {
                        resolve(data);
                    }
                };
                try {
                    bridge.call(url, JSON.stringify(params || {}));
                }
                catch (e) {
                    reject(e);
                }
                return;
            }
            var runtime = window.webOS;
            if (runtime && runtime.service && runtime.service.request) {
                var m = url.match(/^luna:\/\/([^/]+)\/(.+)$/);
                if (!m) {
                    reject(new Error('bad luna url'));
                    return;
                }
                runtime.service.request('luna://' + m[1], {
                    method: m[2],
                    parameters: params || {},
                    onSuccess: function (r) { resolve(r); },
                    onFailure: function (e) {
                        reject(new Error(e.errorText || 'Luna call failed'));
                    }
                });
                return;
            }
            reject(new Error('No Luna bridge available (not running on webOS?)'));
        });
    }
    function shq(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'";
    }
    function exec(command) {
        return luna(HBC + '/exec', { command: command }).then(function (res) {
            var text = (res.stdoutString || '').trim();
            if (text)
                log(text);
            var err = (res.stderrString || '').trim();
            if (err)
                log('stderr: ' + err);
            return res;
        });
    }
    function getFolder() {
        return luna(HBC + '/getAppInfo', { id: APP_ID }).then(function (res) {
            if (!res.appInfo || !res.appInfo.folderPath) {
                throw new Error('Could not resolve app folder path');
            }
            return res.appInfo.folderPath;
        });
    }
    function ctl(action) {
        return getFolder().then(function (dir) {
            return exec('sh ' + shq(dir + '/init/nospy-ctl.sh') + ' ' + action);
        });
    }
    // run a command and stream the output
    function spawn(command, onChunk) {
        return new Promise(function (resolve, reject) {
            var Bridge = window.PalmServiceBridge;
            if (typeof Bridge !== 'function') {
                exec(command).then(resolve, reject);
                return;
            }
            var bridge = new Bridge();
            var settled = false;
            bridge.onservicecallback = function (msg) {
                var data;
                try {
                    data = JSON.parse(msg);
                }
                catch (e) {
                    return;
                }
                if (data.returnValue === false) {
                    if (!settled) {
                        settled = true;
                        reject(new Error(data.errorText || 'spawn failed'));
                    }
                    return;
                }
                if (data.stdoutString)
                    onChunk(data.stdoutString);
                if (data.stderrString)
                    onChunk(data.stderrString);
                if (data.event === 'close' || data.event === 'exit') {
                    if (!settled) {
                        settled = true;
                        resolve(data);
                    }
                }
            };
            try {
                bridge.call(HBC + '/spawn', JSON.stringify({ command: command }));
            }
            catch (e) {
                if (!settled) {
                    settled = true;
                    reject(e);
                }
            }
        });
    }
    function parseStatus(text) {
        var map = {};
        (text || '').split('\n').forEach(function (line) {
            var i = line.indexOf('=');
            if (i > 0)
                map[line.slice(0, i)] = line.slice(i + 1).trim();
        });
        return map;
    }
    function toArray(list) {
        var arr = [];
        for (var i = 0; i < list.length; i++)
            arr.push(list[i]);
        return arr;
    }
    function toggleButtons() {
        return toArray(document.querySelectorAll('.layer[data-key]'));
    }
    function renderToggles(map) {
        toggleButtons().forEach(function (btn) {
            var key = btn.getAttribute('data-key');
            var on = !!key && map[key] === 'on';
            btn.classList.toggle('on', on);
            btn.setAttribute('aria-checked', on ? 'true' : 'false');
        });
    }
    function updateMainButton() {
        var b = document.getElementById('btn-main');
        if (!b)
            return;
        b.classList.remove('pending', 'danger');
        if (!enabled) {
            b.textContent = 'Enable protection';
        }
        else if (dirty) {
            b.textContent = 'Update protection';
            b.classList.add('pending');
        }
        else {
            b.textContent = 'Disable protection';
            b.classList.add('danger');
        }
    }
    function setTag(text, cls) {
        var tag = document.getElementById('dev-root');
        tag.textContent = text;
        tag.className = 'tag' + (cls ? ' ' + cls : '');
    }
    function renderState(map, isRoot) {
        enabled = map.autostart === 'on';
        document.getElementById('r-domains').textContent = map.blocklist || '—';
        document.getElementById('r-hosts').textContent =
            map.hosts === 'ours' ? 'active' : (map.hosts === 'external' ? 'other' : 'off');
        document.getElementById('r-voice').textContent = map.voice === 'stopped' ? 'stopped' : 'running';
        document.getElementById('r-ads').textContent = map.ads === 'stopped' ? 'stopped' : 'running';
        var verdict = document.getElementById('verdict');
        var explain = document.getElementById('explain');
        verdict.classList.remove('is-secure', 'is-warn', 'is-danger');
        appEl.classList.remove('secured', 'pending');
        if (!isRoot) {
            setTag('no root', 'bad');
            verdict.textContent = 'Needs root';
            explain.textContent = 'Install and enable the Homebrew Channel, then reopen this app.';
            verdict.classList.add('is-danger');
        }
        else {
            setTag('rooted', 'ok');
            if (!enabled) {
                verdict.textContent = 'Not protected';
                explain.textContent = 'This TV can still send viewing, ad and voice data.';
                verdict.classList.add('is-danger');
            }
            else if (dirty) {
                verdict.textContent = 'Changes pending';
                explain.textContent = 'Your settings changed. Apply them to re-assert every protection.';
                verdict.classList.add('is-warn');
                appEl.classList.add('secured', 'pending');
            }
            else {
                verdict.textContent = 'Protected';
                explain.textContent = 'Viewing, ad and voice data are not leaving the TV.';
                verdict.classList.add('is-secure');
                appEl.classList.add('secured');
            }
        }
        updateMainButton();
    }
    function refresh() {
        return luna(HBC + '/checkRoot', {}).then(function (res) {
            var isRoot = !!res.returnValue;
            if (!isRoot) {
                renderState({}, false);
                return null;
            }
            return ctl('status').then(function (r) {
                var map = parseStatus(r.stdoutString);
                renderToggles(map);
                renderState(map, true);
                return null;
            });
        }).catch(function (e) {
            renderState({}, false);
            log('status: ' + errmsg(e));
            return null;
        });
    }
    function allButtons() {
        return toArray(document.querySelectorAll('button'));
    }
    // lock the ui while something runs, then put focus back
    function busy(on) {
        if (on) {
            restoreFocus = document.activeElement;
        }
        allButtons().forEach(function (b) { b.disabled = on; });
        if (!on) {
            var target = document.getElementById('btn-main');
            if (restoreFocus instanceof HTMLButtonElement &&
                restoreFocus.offsetParent !== null && !restoreFocus.disabled) {
                target = restoreFocus;
            }
            if (target)
                target.focus();
            restoreFocus = null;
        }
    }
    // run the passed function, refresh after
    function run(label, fn, then) {
        busy(true);
        log('> ' + label);
        return Promise.resolve()
            .then(fn)
            .then(then)
            .catch(function (e) { log('! ' + errmsg(e)); showConsole(true); })
            .then(function () { busy(false); });
    }
    toggleButtons().forEach(function (btn) {
        btn.addEventListener('click', function () {
            var key = btn.getAttribute('data-key');
            if (!key)
                return;
            var next = btn.classList.contains('on') ? 'off' : 'on';
            run(key + ' = ' + next, function () {
                return ctl('set ' + key + ' ' + next);
            }, function () {
                if (enabled)
                    dirty = true;
                return refresh();
            });
        });
    });
    document.getElementById('btn-main').addEventListener('click', function () {
        if (!enabled) {
            run('Enable protection', function () { return ctl('enable'); }, function () {
                dirty = false;
                return refresh();
            });
        }
        else if (dirty) {
            run('Update protection', function () { return ctl('apply'); }, function () {
                dirty = false;
                return refresh();
            });
        }
        else {
            run('Disable protection', function () { return ctl('disable'); }, function () {
                dirty = false;
                return refresh();
            });
        }
    });
    document.getElementById('btn-purge').addEventListener('click', function () {
        run('Purge ACR and voice residue', function () { return ctl('purge'); }, refresh);
    });
    document.getElementById('btn-selftest').addEventListener('click', function () {
        showConsole(true);
        busy(true);
        log('> Self-test');
        getFolder()
            .then(function (dir) {
            return spawn('sh ' + shq(dir + '/init/nospy-ctl.sh') + ' selftest', function (chunk) {
                out.textContent = (out.textContent || '') + chunk;
                consoleEl.scrollTop = consoleEl.scrollHeight;
            });
        })
            .catch(function (e) { log('! ' + errmsg(e)); })
            .then(function () { busy(false); });
    });
    document.getElementById('btn-refresh').addEventListener('click', function () {
        run('Refresh', refresh);
    });
    document.getElementById('btn-log').addEventListener('click', function () {
        showConsole(consoleEl.hidden);
    });
    // d-pad navigation
    function focusables() {
        return toArray(document.querySelectorAll('button:not([disabled])'))
            .filter(function (el) { return el.offsetParent !== null; });
    }
    function focusElement(el) {
        if (!el)
            return;
        el.focus();
        if (el.scrollIntoView)
            el.scrollIntoView({ block: 'nearest' });
    }
    function centerX(el) {
        var r = el.getBoundingClientRect();
        return r.left + r.width / 2;
    }
    // group buttons into rows so left/right stays in the row
    function layoutRows() {
        var rows = [];
        focusables().forEach(function (el) {
            var r = el.getBoundingClientRect();
            var cy = r.top + r.height / 2;
            var row = null;
            for (var i = 0; i < rows.length; i++) {
                if (Math.abs(rows[i].cy - cy) < Math.max(r.height, rows[i].h) / 2) {
                    row = rows[i];
                    break;
                }
            }
            if (row) {
                row.items.push(el);
            }
            else {
                rows.push({ cy: cy, h: r.height, items: [el] });
            }
        });
        rows.sort(function (a, b) { return a.cy - b.cy; });
        rows.forEach(function (row) {
            row.items.sort(function (a, b) { return centerX(a) - centerX(b); });
        });
        return rows;
    }
    function locate(rows, el) {
        if (!el)
            return null;
        for (var i = 0; i < rows.length; i++) {
            for (var j = 0; j < rows[i].items.length; j++) {
                if (rows[i].items[j] === el)
                    return { row: i, col: j };
            }
        }
        return null;
    }
    function moveFocus(dir) {
        var rows = layoutRows();
        if (!rows.length)
            return;
        var pos = locate(rows, document.activeElement);
        if (!pos) {
            focusElement(rows[0].items[0]);
            return;
        }
        var row = rows[pos.row];
        if (dir === 'left') {
            if (pos.col > 0)
                focusElement(row.items[pos.col - 1]);
            return;
        }
        if (dir === 'right') {
            if (pos.col < row.items.length - 1)
                focusElement(row.items[pos.col + 1]);
            return;
        }
        var targetRow = rows[pos.row + (dir === 'down' ? 1 : -1)];
        if (!targetRow)
            return;
        // single button row goes to the start of the next row
        if (row.items.length === 1 || targetRow.items.length === 1) {
            focusElement(targetRow.items[0]);
            return;
        }
        var active = document.activeElement;
        var cx = active ? centerX(active) : 0;
        var best = targetRow.items[0];
        var bestDist = Infinity;
        targetRow.items.forEach(function (el) {
            var d = Math.abs(centerX(el) - cx);
            if (d < bestDist) {
                bestDist = d;
                best = el;
            }
        });
        focusElement(best);
    }
    var KEY_DIR = { 37: 'left', 38: 'up', 39: 'right', 40: 'down' };
    document.addEventListener('keydown', function (e) {
        if (KEY_DIR[e.keyCode]) {
            e.preventDefault();
            moveFocus(KEY_DIR[e.keyCode]);
            return;
        }
        if (e.keyCode === 13 || e.keyCode === 32) {
            var el = document.activeElement;
            if (el && el.tagName === 'BUTTON') {
                e.preventDefault();
                el.click();
            }
        }
    }, true);
    refresh();
    var main = document.getElementById('btn-main');
    if (main)
        main.focus();
})();
