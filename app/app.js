// lifesgoodwithoutspying frontend: the log, rendering and actions. tv.js talks
// to the TV, status.js reads its status, nav.js moves focus.
'use strict';

(function () {
    var consoleEl = document.getElementById('console');
    var out = document.getElementById('out');
    var i18n = window.nospyI18n;
    var t = i18n.t;
    var setText = i18n.setText;
    var status = window.nospyStatus;
    var nav = window.nospyNav(consoleEl);
    var tv = window.nospyTv(log, appIsActive);

    // What the TV last told us. root is undefined until checkRoot answers,
    // then true, false (not rooted) or null (no answer). statusMap is the
    // raw status, which a local set edits; model is read from it.
    var root;
    var statusMap = null;
    var model = null;
    var appVersion = '';
    // An action is running: every button is disabled until it ends.
    var busy = false;
    // The main button's job is running, so the hero says "Applying…".
    var applying = false;

    function errmsg(e) {
        return e instanceof Error ? e.message : String(e);
    }
    function byId(id) {
        return document.getElementById(id);
    }
    function each(selector, fn) {
        Array.prototype.forEach.call(document.querySelectorAll(selector), fn);
    }
    function clear(el) {
        while (el.firstChild)
            el.removeChild(el.firstChild);
    }
    function make(tag, cls, text) {
        var el = document.createElement(tag);
        if (cls)
            el.className = cls;
        if (text !== undefined)
            el.textContent = text;
        return el;
    }

    // ------------------------------------------------------------ log

    // Cap the retained log; the oldest lines are dropped past this.
    var MAX_LOG_LINES = 2000;
    var logLines = [];
    // One text node per line, trimmed to MAX_LOG_LINES, so the buffer is not
    // re-parsed on every append and cannot grow for the whole session.
    function log(line) {
        if (!line && line !== 0)
            return;
        var stick = consoleAtBottom();
        var time = new Date().toLocaleTimeString();
        var node = document.createTextNode('[' + time + '] ' + line + '\n');
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
    function consoleAtBottom() {
        if (consoleEl.clientHeight === 0)
            return true;
        return consoleEl.scrollTop >= maxConsoleScroll() - 8;
    }
    function scrollConsoleToBottom() {
        if (consoleEl.clientHeight !== 0)
            consoleEl.scrollTop = maxConsoleScroll();
    }
    // Arriving at the log parks it on the newest line.
    consoleEl.addEventListener('focus', scrollConsoleToBottom);

    // ------------------------------------------------------------ timers

    // SDP grace period: status gives the seconds left; count down locally
    // between polls.
    var graceDeadline = 0;
    var graceTimer = null;
    function graceLeft() {
        return Math.max(0, Math.ceil((graceDeadline - Date.now()) / 1000));
    }
    function updateGrace() {
        if (model && model.hostsWait !== null)
            graceDeadline = Date.now() + model.hostsWait * 1000;
        var waiting = !!model && model.sdpWait;
        if (waiting && graceTimer === null) {
            graceTimer = setInterval(function () {
                if (graceLeft() > 0)
                    render();
            }, 1000);
        }
        else if (!waiting && graceTimer !== null) {
            clearInterval(graceTimer);
            graceTimer = null;
        }
    }

    // A short confirmation under the verdict, such as after a purge.
    var flash = null;
    var flashTimer = null;
    function showFlash(text) {
        flash = text;
        clearTimeout(flashTimer);
        flashTimer = setTimeout(function () {
            flash = null;
            render();
        }, 4000);
        render();
    }

    // ------------------------------------------------------------ render

    // Put a string in an element. Lists from status.js are the one special
    // case: groups become their translated labels, and process names show as
    // code so they read as identifiers. Everything else goes through i18n.
    function say(el, key, params) {
        if (params && params.groups)
            params = { groups: params.groups.map(function (g) { return t(g.label); }).join(', ') };
        if (!params || !params.names) {
            setText(el, key, params);
            return;
        }
        el.removeAttribute('data-i18n');
        clear(el);
        var parts = t(key).split('{names}');
        for (var i = 0; i < parts.length; i++) {
            if (i) {
                params.names.forEach(function (name, j) {
                    if (j)
                        el.appendChild(document.createTextNode(', '));
                    el.appendChild(make('code', '', name));
                });
            }
            el.appendChild(document.createTextNode(parts[i]));
        }
    }
    function fact(f) {
        var span = make('span');
        span.appendChild(make('i', 'dot ok'));
        var parts = t(f.key).split('{n}');
        span.appendChild(document.createTextNode(parts[0]));
        if (parts.length > 1) {
            span.appendChild(make('b', '', String(f.n)));
            span.appendChild(document.createTextNode(parts[1]));
        }
        return span;
    }
    function renderHero(s) {
        var verdict = byId('verdict'), why = byId('why'), facts = byId('facts');
        setText(verdict, s.verdict);
        verdict.className = 'verdict' + (s.cls ? ' ' + s.cls : '');
        why.className = flash ? 'why ok' : 'why';
        why.hidden = !flash && !s.why;
        if (flash) {
            why.removeAttribute('data-i18n');
            why.textContent = flash;
        }
        else if (s.why) {
            say(why, s.why, s.params);
        }
        clear(facts);
        facts.hidden = !!flash || !s.facts;
        if (s.facts)
            s.facts.forEach(function (f) { facts.appendChild(fact(f)); });

        byId('progress').hidden = !s.busy;
        var action = status.mainAction(model), main = byId('btn-main');
        setText(main, action.key);
        main.className = 'primary' + (action.cls ? ' ' + action.cls : '');
        main.hidden = !!(s.solo || s.busy);
        var retry = byId('btn-retry');
        retry.hidden = !s.retry;
        if (s.retry)
            setText(retry, s.retry);
        byId('btn-openlog').hidden = !s.openLog;
        [main, retry, byId('btn-openlog')].forEach(function (b) {
            b.disabled = busy;
        });
        byId('hero').className = 'hero' + (s.solo ? ' solo' : '');
        byId('status').hidden = !!s.solo;
    }
    function groupLine(group) {
        var line = status.groupLine(group), el = make('span', 'st' + (line.cls ? ' ' + line.cls : ''));
        say(el, line.key, line.params);
        return el;
    }
    // The status column is hidden until there is a status to show.
    function renderStatus() {
        var box = byId('groups');
        clear(box);
        if (!model)
            return;
        model.groups.forEach(function (g) {
            var el = make('div', 'group');
            el.appendChild(make('span', 'nm', t(g.label)));
            var pips = make('span', 'pips');
            g.procs.forEach(function (p) {
                pips.appendChild(make('i', 'pip ' + p.pip));
            });
            el.appendChild(pips);
            el.appendChild(groupLine(g));
            box.appendChild(el);
        });
        each('[data-cell]', function (el) {
            var c = status.cell(model, el.getAttribute('data-cell'), graceLeft());
            el.className = c.cls;
            setText(el, c.key, c.params);
        });
    }
    function renderPanes() {
        var usable = root === true && !!model;
        each('.item[data-key]', function (btn) {
            var key = btn.getAttribute('data-key'), on = usable && !!model.saved[key];
            btn.classList.toggle('on', on);
            btn.classList.toggle('pend', usable && !!model.dirty[key]);
            btn.setAttribute('aria-checked', on ? 'true' : 'false');
            btn.disabled = busy || !usable || (key === 'purge.boot' && !on);
            if (key === 'purge.boot')
                setText(btn.querySelector('small'), on ? 'item.purge.boot.savedOn' : 'item.purge.boot.detail');
        });
        setText(byId('sdp-detail'), usable && model.saved['clock.ntp'] ? 'item.domains.sdp.detailNtp' : 'item.domains.sdp.detail');
        var groups = {};
        if (usable)
            model.groups.forEach(function (g) { groups[g.id] = g; });
        each('.svc[data-group]', function (card) {
            var g = groups[card.getAttribute('data-group')];
            var state = card.querySelector('.state'), procs = card.querySelector('.procs');
            clear(state);
            clear(procs);
            if (!g)
                return;
            state.appendChild(groupLine(g));
            g.procs.forEach(function (p) {
                var row = make('span', p.pip);
                row.appendChild(make('i', 'pip ' + p.pip));
                row.appendChild(document.createTextNode(p.name));
                procs.appendChild(row);
            });
        });
    }
    // Each category counts the toggles its own pane holds.
    function paneKeys(pane) {
        return Array.prototype.map.call(document.querySelectorAll('#pane-' + pane + ' .item[data-key]'),
            function (btn) { return btn.getAttribute('data-key'); });
    }
    function renderRail() {
        var usable = root === true && !!model;
        each('.rail [data-pane]', function (btn) {
            btn.disabled = busy;
        });
        each('[data-count]', function (el) {
            el.textContent = usable ? t('rail.count', status.onCount(model, paneKeys(el.getAttribute('data-count')))) : '';
        });
        var fault = root === true ? status.serviceFault(model) : '';
        var dot = byId('svc-dot');
        dot.hidden = !fault;
        dot.className = 'dot ' + fault;
    }
    var ROOT_TEXT = {
        'true': ['ok', 'footer.rooted'],
        'false': ['bad', 'footer.noRoot'],
        'null': ['warn', 'footer.noAnswer'],
        'undefined': ['', 'footer.checking']
    };
    function renderFooter() {
        var r = ROOT_TEXT[String(root)];
        byId('root-dot').className = 'dot ' + r[0];
        setText(byId('root-text'), r[1]);
        var version = byId('app-version');
        version.textContent = 'LGWS ' + appVersion;
        version.hidden = !appVersion;
        byId('btn-purge').disabled = true;
        byId('btn-selftest').disabled = busy || root !== true;
        byId('btn-language').disabled = busy;
    }
    function render() {
        renderHero(status.hero(model, root, applying, graceLeft()));
        renderStatus();
        renderPanes();
        renderRail();
        renderFooter();
    }

    // ------------------------------------------------------------ panes

    function showPane(id) {
        each('.rail [data-pane]', function (btn) {
            var on = btn.getAttribute('data-pane') === id;
            btn.classList.toggle('sel', on);
            byId('pane-' + btn.getAttribute('data-pane')).hidden = !on;
        });
        if (id === 'log')
            scrollConsoleToBottom();
    }
    // Moving along the rail switches panes, as TV menus do, so the pane on
    // the right is always the one the focused category names.
    each('.rail [data-pane]', function (btn) {
        var show = function () {
            showPane(btn.getAttribute('data-pane'));
        };
        btn.addEventListener('focus', show);
        btn.addEventListener('click', show);
    });

    // ------------------------------------------------------------ refresh

    // Status is not a free call (the helper inspects the process table), so
    // poll only while an active app shows a state that changes by itself: the
    // SDP grace period, or a job left running.
    var STATUS_POLL_MS = 5000;
    var statusPollTimer = null;
    function appIsActive() {
        return !(document.hidden === true || document.webkitHidden === true ||
            document.visibilityState === 'hidden');
    }
    function stopStatusPolling() {
        if (statusPollTimer !== null) {
            clearTimeout(statusPollTimer);
            statusPollTimer = null;
        }
    }
    function scheduleStatusPolling() {
        stopStatusPolling();
        if (!appIsActive() || !model || (!model.sdpWait && !model.jobRunning))
            return;
        statusPollTimer = setTimeout(function () {
            statusPollTimer = null;
            if (appIsActive())
                refresh({ quiet: true });
        }, STATUS_POLL_MS);
    }
    function setStatus(map) {
        statusMap = map;
        model = map ? status.read(map) : null;
        updateGrace();
    }
    function refresh(options) {
        var quiet = !!(options && options.quiet);
        stopStatusPolling();
        return tv.hbc('checkRoot', {}, null, true).then(function () {
            return true;
        }, function (e) {
            // Only a plain returnValue:false answer means "not root".
            if (e.data && e.data.returnValue === false && !e.data.errorText)
                return false;
            throw e;
        }).then(function (isRoot) {
            root = isRoot;
            if (!isRoot) {
                setStatus(null);
                return null;
            }
            return tv.ctl('status', quiet).then(function (r) {
                setStatus(tv.parseStatus(r.stdoutString));
            });
        }).catch(function (e) {
            // A quiet poll keeps the last state visible and retries; a manual
            // refresh shows that the TV didn't answer.
            if (!quiet) {
                root = null;
                setStatus(null);
                log('status: ' + errmsg(e));
            }
        }).then(function () {
            render();
            scheduleStatusPolling();
        });
    }

    // ------------------------------------------------------------ actions

    // Run one action with every button disabled, then put focus back. A
    // failure shows the log, and refreshes in case it changed the TV.
    function run(label, fn, then, isJob) {
        var restoreFocus = document.activeElement;
        busy = true;
        applying = !!isJob;
        stopStatusPolling();
        render();
        log('> ' + label);
        return Promise.resolve()
            .then(fn)
            .then(then)
            .catch(function (e) {
                log('! ' + errmsg(e));
                showPane('log');
                return refresh();
            })
            .then(function () {
                busy = false;
                applying = false;
                render();
                var target = restoreFocus;
                if (!(target instanceof HTMLElement) || target.offsetParent === null || target.disabled)
                    target = nav.defaultFocus();
                nav.focus(target);
                scheduleStatusPolling();
            });
    }
    each('.item[data-key]', function (btn) {
        btn.addEventListener('click', function () {
            var key = btn.getAttribute('data-key');
            var next = btn.classList.contains('on') ? 'off' : 'on';
            // set only saves the key; the main button applies every change at
            // once. A status call costs seconds, so update the view from the
            // last known state instead.
            run(key + ' = ' + next, function () {
                return tv.ctl('set ' + key + ' ' + next, true);
            }, function () {
                if (!statusMap)
                    return refresh();
                statusMap['saved.' + key] = next;
                setStatus(statusMap);
            });
        });
    });
    byId('btn-main').addEventListener('click', function () {
        var action = status.mainAction(model);
        run(action.label, function () { return tv.job(action.command); }, refresh, true);
    });
    byId('btn-purge').addEventListener('click', function () {
        run('Purge ACR and voice residue', function () { return tv.ctl('purge'); }, function (res) {
            var m = /purged (\d+)/.exec((res && res.stdoutString) || '');
            showFlash(m ? t('flash.purged', { n: m[1] }) : t('flash.purgedNone'));
        });
    });
    byId('btn-selftest').addEventListener('click', function () {
        showPane('log');
        run('Self-test', function () { return tv.ctl('selftest'); });
    });
    byId('btn-retry').addEventListener('click', function () {
        run('Refresh', refresh);
    });
    byId('btn-openlog').addEventListener('click', function () {
        showPane('log');
        nav.focus(consoleEl);
    });
    byId('btn-language').addEventListener('click', function () {
        i18n.cycle();
    });
    document.addEventListener('nospy-language-change', render);

    // ------------------------------------------------------------ lifecycle

    // webOS 5-era WebKit uses webkitvisibilitychange; newer engines use the
    // standard event. Stop background work when hidden and re-check on resume.
    function visibilityChanged() {
        stopStatusPolling();
        if (appIsActive())
            refresh({ quiet: true });
    }
    var visibilityEvent = typeof document.hidden !== 'undefined' ? 'visibilitychange' :
        (typeof document.webkitHidden !== 'undefined' ? 'webkitvisibilitychange' : 'visibilitychange');
    document.addEventListener(visibilityEvent, visibilityChanged, true);
    document.addEventListener('webOSRelaunch', function () {
        // webOSRelaunch can arrive just before document.hidden is cleared.
        stopStatusPolling();
        refresh({ quiet: true });
    }, true);
    // The menu language lives in the settings service; navigator.language in
    // the web runtime does not always follow it.
    tv.luna('luna://com.webos.settingsservice/getSystemSettings', { keys: ['localeInfo'] }).then(function (res) {
        var info = res && res.settings && res.settings.localeInfo;
        i18n.setSystemLocale(info && info.locales && info.locales.UI);
    }).catch(function () { });
    tv.luna('luna://com.webos.service.tv.systemproperty/getSystemInfo', { keys: ['sdkVersion'] }).then(function (res) {
        var el = byId('webos-version');
        if (res && res.sdkVersion) {
            el.textContent = 'webOS ' + res.sdkVersion;
            el.hidden = false;
        }
    }).catch(function () { });
    tv.appInfo().then(function (info) {
        appVersion = info.version || '';
        render();
    }, function () { });
    render();
    nav.focus(nav.defaultFocus());
    // Until the first status the hero has no buttons, so focus starts on the
    // rail; move it to the main button once there is one.
    refresh().then(function () {
        var active = document.activeElement;
        if (nav.zoneOf(active) === null || active === nav.selectedRail())
            nav.focus(nav.defaultFocus());
    });
})();
