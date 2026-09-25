// lifesgoodwithoutspying frontend.
'use strict';

(function () {
    var APP_ID = 'ooo.lew.lifesgoodwithoutspying';
    var HBC = 'luna://org.webosbrew.hbchannel.service';
    var appEl = document.getElementById('app');
    var consoleEl = document.getElementById('console');
    var out = document.getElementById('out');
    var logView = document.getElementById('logview');
    var enabled = false;
    var dirty = false;
    var restoreFocus = null;
    var STATUS_POLL_MS = 5000;
    var statusPollTimer = null;
    var lastStatus = null;
    var navigationRowsCache = null;
    var logBtn = document.getElementById('btn-log');
    // Cap the retained log; the oldest lines are dropped past this.
    var MAX_LOG_LINES = 2000;
    var logLines = [];
    function errmsg(e) {
        return e instanceof Error ? e.message : String(e);
    }
    function showConsole(show) {
        logView.hidden = !show;
        var layers = document.getElementById('layers');
        if (layers)
            layers.hidden = show;
        invalidateNavigation();
        if (show)
            scrollConsoleToBottom();
        if (logBtn)
            logBtn.textContent = show ? 'Hide log' : 'Show log';
    }
    // One text node per line, trimmed to MAX_LOG_LINES, so the buffer is not
    // re-parsed on every append and cannot grow for the whole session.
    function log(line) {
        if (!line && line !== 0)
            return;
        var stick = consoleAtBottom();
        var t = new Date().toLocaleTimeString();
        var node = document.createTextNode('[' + t + '] ' + line + '\n');
        out.appendChild(node);
        logLines.push(node);
        while (logLines.length > MAX_LOG_LINES) {
            var old = logLines.shift();
            if (old.parentNode)
                old.parentNode.removeChild(old);
        }
        if (stick)
            scrollConsoleToBottom();
    }
    function maxConsoleScroll() {
        return Math.max(0, consoleEl.scrollHeight - consoleEl.clientHeight);
    }
    function consoleAtBottom(slack) {
        if (consoleEl.clientHeight === 0)
            return true;
        return consoleEl.scrollTop >= maxConsoleScroll() - (slack || 8);
    }
    function scrollConsoleToBottom() {
        if (consoleEl.clientHeight === 0)
            return;
        consoleEl.scrollTop = maxConsoleScroll();
    }
    // True when the view actually moved, so a keypress at either end of the
    // buffer can hand focus back to the buttons instead of spinning.
    function scrollConsoleBy(delta) {
        var before = consoleEl.scrollTop;
        consoleEl.scrollTop = before + delta;
        return consoleEl.scrollTop !== before;
    }
    // Arriving at the log parks it on the newest line.
    consoleEl.addEventListener('focus', function () {
        scrollConsoleToBottom();
    });
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
    function exec(command, quiet) {
        return luna(HBC + '/exec', { command: command }).then(function (res) {
            if (!quiet) {
                var text = (res.stdoutString || '').trim();
                if (text)
                    log(text);
                var err = (res.stderrString || '').trim();
                if (err)
                    log('stderr: ' + err);
            }
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
    function ctl(action, quiet) {
        return getFolder().then(function (dir) {
            return exec('sh ' + shq(dir + '/init/nospy-ctl.sh') + ' ' + action, quiet);
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
            map.hosts === 'ours' ? 'active' :
            (map.hosts === 'waiting' ? 'waiting' :
            (map.hosts === 'external' ? 'other' : 'off'));
        var dnsRuntime = map.dns_filter || 'unavailable';
        var dnsEnabled = map['dns.filter'] === 'on';
        var dnsIpv6Disabled = map['dns.disable_ipv6'] === 'on';
        document.getElementById('r-dns').textContent =
            dnsEnabled ?
                (dnsRuntime === 'yes' ? 'active' :
                    (dnsRuntime === 'no' ? 'pending' : 'unavailable')) : 'off';
        document.getElementById('r-ipv6').textContent =
            !dnsEnabled ? 'not managed' : (dnsIpv6Disabled ? 'disabled' : 'preserved');
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
                explain.textContent = 'This TV can still send viewing, ad, and voice data.';
                verdict.classList.add('is-danger');
            }
            else if (dirty) {
                verdict.textContent = 'Changes pending';
                explain.textContent = 'Your settings changed. Select "Update protection" to apply them.';
                verdict.classList.add('is-warn');
                appEl.classList.add('secured', 'pending');
            }
            else if (map['dns.filter'] === 'on' && map.dns_filter !== 'yes') {
                verdict.textContent = 'DNS filter needs attention';
                explain.textContent = 'The DNS filter is enabled but its ConnMan handoff is not active. Check the log and helper status.';
                verdict.classList.add('is-warn');
                appEl.classList.add('secured', 'pending');
            }
            else if (map['dns.filter'] === 'on' && map['dns.disable_ipv6'] === 'off') {
                verdict.textContent = 'DNS filter active (IPv4 path)';
                explain.textContent = 'ConnMan IPv6 is preserved. IPv6 DNS may bypass the local helper; enable the companion IPv6 switch for strict coverage.';
                verdict.classList.add('is-warn');
                appEl.classList.add('secured', 'pending');
            }
            else if (map.hosts === 'waiting') {
                verdict.textContent = 'SDP grace period';
                explain.textContent = 'Other domain blocks are active. SDP will be blocked after the 60-second clock-sync grace period.';
                verdict.classList.add('is-warn');
                appEl.classList.add('secured', 'pending');
            }
            else {
                verdict.textContent = 'Protected';
                explain.textContent = 'Targeted ad and voice services are stopped; enabled domain blocks are applied.';
                verdict.classList.add('is-secure');
                appEl.classList.add('secured');
            }
        }
        updateMainButton();
        invalidateNavigation();
    }
    // The SDP worker changes the host state asynchronously. Status is not a
    // free call (the helper inspects the process table), so poll only while an
    // active app is actually showing that grace-period state.
    function appIsActive() {
        if (document.hidden === true || document.webkitHidden === true ||
            document.visibilityState === 'hidden')
            return false;
        return true;
    }
    function stopStatusPolling() {
        if (statusPollTimer !== null) {
            clearTimeout(statusPollTimer);
            statusPollTimer = null;
        }
    }
    function scheduleStatusPolling() {
        stopStatusPolling();
        if (!appIsActive() || !lastStatus || lastStatus.hosts !== 'waiting')
            return;
        statusPollTimer = setTimeout(function () {
            statusPollTimer = null;
            if (appIsActive())
                refresh({ quiet: true });
        }, STATUS_POLL_MS);
    }
    function refresh(options) {
        var quiet = !!(options && options.quiet);
        stopStatusPolling();
        return luna(HBC + '/checkRoot', {}).then(function (res) {
            var isRoot = !!res.returnValue;
            if (!isRoot) {
                lastStatus = null;
                renderState({}, false);
                return null;
            }
            return ctl('status', quiet).then(function (r) {
                var map = parseStatus(r.stdoutString);
                lastStatus = map;
                renderToggles(map);
                renderState(map, true);
                return null;
            });
        }).catch(function (e) {
            // A quiet poll keeps the last state visible and retries; a manual
            // refresh retains the existing error state and log behavior.
            if (!quiet) {
                lastStatus = null;
                renderState({}, false);
                log('status: ' + errmsg(e));
            }
            return null;
        }).then(function (result) {
            scheduleStatusPolling();
            return result;
        });
    }
    function allButtons() {
        return toArray(document.querySelectorAll('button'));
    }
    // lock the ui while something runs, then put focus back
    function busy(on) {
        if (on) {
            stopStatusPolling();
            restoreFocus = document.activeElement;
        }
        allButtons().forEach(function (b) { b.disabled = on; });
        invalidateNavigation();
        if (!on) {
            var target = document.getElementById('btn-main');
            if (restoreFocus instanceof HTMLButtonElement &&
                restoreFocus.offsetParent !== null && !restoreFocus.disabled) {
                target = restoreFocus;
            }
            if (target)
                target.focus();
            restoreFocus = null;
            scheduleStatusPolling();
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
        run('Self-test', function () { return ctl('selftest'); });
    });
    document.getElementById('btn-refresh').addEventListener('click', function () {
        run('Refresh', refresh);
    });
    logBtn.addEventListener('click', function () {
        showConsole(logView.hidden);
    });
    // d-pad navigation
    function invalidateNavigation() {
        navigationRowsCache = null;
    }
    function focusables() {
        return toArray(document.querySelectorAll('button:not([disabled]), #console'))
            .filter(function (el) { return el.offsetParent !== null; });
    }
    function focusElement(el) {
        if (!el)
            return;
        try {
            el.focus({ preventScroll: true });
        }
        catch (_error) {
            el.focus();
        }
        // The layers list scrolls itself; anything else goes through
        // scrollIntoView below.
        var scroller = document.querySelector('.layers');
        if (scroller && scroller.contains(el)) {
            var top = el.__nospyNavTop;
            var bottom = el.__nospyNavBottom;
            if (typeof top === 'number' && typeof bottom === 'number') {
                var viewportHeight = scroller.__nospyNavViewportHeight || scroller.clientHeight;
                var currentTop = scroller.scrollTop;
                if (top < currentTop)
                    scroller.scrollTop = top;
                else if (bottom > currentTop + viewportHeight)
                    scroller.scrollTop = bottom - viewportHeight;
            }
            else {
                var item = el.getBoundingClientRect();
                var view = scroller.getBoundingClientRect();
                if (item.top < view.top)
                    scroller.scrollTop -= view.top - item.top;
                else if (item.bottom > view.bottom)
                    scroller.scrollTop += item.bottom - view.bottom;
            }
        }
        else if (el.scrollIntoView) {
            el.scrollIntoView({ block: 'nearest' });
        }
    }
    function centerX(el) {
        if (typeof el.__nospyNavCenterX === 'number')
            return el.__nospyNavCenterX;
        var r = el.getBoundingClientRect();
        return r.left + r.width / 2;
    }
    // Group buttons into rows once per layout change. Remote navigation then
    // avoids measuring every button on every key repeat.
    function layoutRows() {
        if (navigationRowsCache !== null)
            return navigationRowsCache;
        var rows = [];
        var scroller = document.querySelector('.layers');
        var scrollerRect = scroller ? scroller.getBoundingClientRect() : null;
        var scrollTop = scroller ? scroller.scrollTop : 0;
        if (scroller)
            scroller.__nospyNavViewportHeight = scroller.clientHeight;
        focusables().forEach(function (el) {
            var r = el.getBoundingClientRect();
            if (scrollerRect) {
                el.__nospyNavTop = r.top - scrollerRect.top + scrollTop;
                el.__nospyNavBottom = el.__nospyNavTop + r.height;
            }
            el.__nospyNavCenterX = r.left + r.width / 2;
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
            row.items.sort(function (a, b) {
                return a.__nospyNavCenterX - b.__nospyNavCenterX;
            });
        });
        navigationRowsCache = rows;
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
    // While the log holds focus the d-pad scrolls it instead of walking the
    // button grid. The rocker reaches us as plain arrow keys on webOS builds
    // where the Magic Remote's wheel is not forwarded to the app.
    function consoleNav(dir) {
        // The log wraps, so the horizontal axis is free to be the way out, and
        // the toolbar toggle doubles as the escape once it relabels itself.
        if (dir === 'left' || dir === 'right') {
            focusElement(logBtn);
            return;
        }
        // Page by four fifths of the view so pages share some context.
        var step = Math.max(40, Math.round(consoleEl.clientHeight * 0.8));
        if (dir === 'down') {
            scrollConsoleBy(step);
            return;
        }
        if (scrollConsoleBy(-step) || consoleEl.scrollTop > 0)
            return;
        focusElement(logBtn);
    }
    window.addEventListener('resize', invalidateNavigation, true);
    var KEY_DIR = { 37: 'left', 38: 'up', 39: 'right', 40: 'down' };
    document.addEventListener('keydown', function (e) {
        var dir = KEY_DIR[e.keyCode];
        if (dir) {
            e.preventDefault();
            if (document.activeElement === consoleEl) {
                consoleNav(dir);
                return;
            }
            moveFocus(dir);
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
    // webOS 5-era WebKit uses webkitvisibilitychange; newer engines use the
    // standard event. Stop background work when hidden and re-check on resume.
    function visibilityChanged() {
        if (appIsActive()) {
            stopStatusPolling();
            refresh({ quiet: true });
        }
        else {
            stopStatusPolling();
        }
    }
    var visibilityEvent = typeof document.hidden !== 'undefined' ? 'visibilitychange' :
        (typeof document.webkitHidden !== 'undefined' ? 'webkitvisibilitychange' : 'visibilitychange');
    document.addEventListener(visibilityEvent, visibilityChanged, true);
    document.addEventListener('webOSRelaunch', function () {
        // webOSRelaunch can arrive just before document.hidden is cleared.
        stopStatusPolling();
        refresh({ quiet: true });
    }, true);
    refresh();
    var main = document.getElementById('btn-main');
    if (main)
        main.focus();
})();
