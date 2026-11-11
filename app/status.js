// What the TV's status means. read() turns nospy-ctl.sh status output into one
// model, once per refresh; the rest decide what the hero, the status cells,
// the service lines and the main button say. No DOM here.
'use strict';

window.nospyStatus = (function () {
    // The toggle behind each service group. A group status reports that isn't
    // listed here still shows, with no toggle of its own.
    var GROUPS = {
        voice: { key: 'voice.stop', label: 'group.voice' },
        ads: { key: 'ads.stop', label: 'group.ads' },
        thinq: { key: 'domains.thinq', label: 'group.thinq' },
        lan: { key: 'lan.block', label: 'group.lan' }
    };

    // map is parseStatus() output: key=value lines in the order printed.
    //   saved.<key>=on|off     saved settings, which the toggles show
    //   applied.<key>=on|off   the settings the last apply used
    //   proc.<group>.<name>=running|stopped|absent|unknown
    //   kept.<group>.<name>=<titles>   left running for the apps registered for it
    //   claimed.<group>.<name>=<title> stubbed, and answered for by that app in
    //                                  place of our stand-in
    function read(map) {
        var enabled = map.autostart === 'on';
        var saved = {}, applied = {}, groups = [], byId = {}, kept = {};
        Object.keys(map).forEach(function (k) {
            var v = map[k], m;
            if ((m = /^saved\.(.+)$/.exec(k))) {
                saved[m[1]] = v === 'on';
            }
            else if ((m = /^applied\.(.+)$/.exec(k))) {
                applied[m[1]] = v === 'on';
            }
            else if ((m = /^kept\.([^.]+)\.(.+)$/.exec(k))) {
                (kept[m[1]] = kept[m[1]] || []).push({ name: m[2], apps: v });
            }
            else if ((m = /^claimed\.([^.]+)\.(.+)$/.exec(k))) {
                (kept[m[1]] = kept[m[1]] || []).push({ name: m[2], apps: v, claimed: true });
            }
            else if ((m = /^proc\.([^.]+)\.(.+)$/.exec(k))) {
                // Names can contain dots; groups can't.
                if (!byId[m[1]]) {
                    byId[m[1]] = { id: m[1], procs: [] };
                    groups.push(byId[m[1]]);
                }
                // An absent process isn't on this TV.
                if (v !== 'absent')
                    byId[m[1]].procs.push({ name: m[2], state: v });
            }
        });
        // A kept process is one more dot in its group, in use by the apps
        // registered for it; it is neither running against the setting nor stopped.
        // A claimed one is LG's process, still stubbed, whose name an app
        // answers for: its own dot turns into the same kind.
        Object.keys(kept).forEach(function (id) {
            if (!byId[id])
                return;
            kept[id].forEach(function (k) {
                var own = k.claimed && byId[id].procs.filter(function (p) { return p.name === k.name; })[0];
                if (own) {
                    own.state = 'kept';
                    own.apps = k.apps;
                }
                else {
                    byId[id].procs.push({ name: k.name, state: 'kept', apps: k.apps });
                }
            });
        });
        // Before the first apply there are no applied lines, and nothing is
        // running yet to differ from the saved settings.
        var appliedKnown = Object.keys(applied).length > 0;
        var live = {}, dirty = {}, dirtyCount = 0;
        Object.keys(saved).forEach(function (k) {
            var a = appliedKnown && k in applied ? applied[k] : saved[k];
            live[k] = enabled && a;
            dirty[k] = enabled && a !== saved[k];
            if (dirty[k])
                dirtyCount++;
        });
        var running = [], unknown = [], stopped = 0;
        groups.forEach(function (g) {
            var def = GROUPS[g.id];
            g.key = def ? def.key : null;
            g.label = def ? def.label : g.id;
            g.saved = g.key ? !!saved[g.key] : true;
            g.live = g.key ? !!live[g.key] : true;
            g.dirty = g.key ? !!dirty[g.key] : false;
            g.kept = g.live ? kept[g.id] || [] : [];
            g.running = [];
            g.unknown = [];
            g.procs.forEach(function (p) {
                // A service that is off isn't a fault, so its processes are idle.
                p.pip = g.live ? p.state : 'idle';
                if (p.pip === 'running')
                    g.running.push(p.name);
                else if (p.pip === 'unknown')
                    g.unknown.push(p.name);
                else if (p.pip === 'stopped')
                    stopped++;
            });
            running = running.concat(g.running);
            if (g.unknown.length)
                unknown.push(g);
        });
        return {
            enabled: enabled,
            saved: saved,
            live: live,
            dirty: dirty,
            anyDirty: enabled && (dirtyCount > 0 || (!appliedKnown && map.changes === 'pending')),
            jobRunning: map.job === 'running',
            blocklist: map.blocklist || '0',
            hostsWait: map.hosts_wait === undefined ? null : parseInt(map.hosts_wait, 10),
            groups: groups,
            running: running,
            unknown: unknown,
            stopped: stopped,
            // With a domain list on, our hosts file should be on top: 'open'
            // means it isn't mounted, 'external' that another one covers it.
            hostsDown: enabled && Object.keys(live).some(function (k) { return k.indexOf('domains.') === 0 && live[k]; }) &&
                (map.hosts === 'open' || map.hosts === 'external') ? map.hosts : '',
            dnsDown: !!live['dns.filter'] && map.dns_filter !== 'yes',
            ipv4Only: !!live['dns.filter'] && !live['dns.disable_ipv6'],
            sdpWait: map.hosts === 'waiting'
        };
    }

    // What the hero says. root is true, false (not rooted), null (no answer)
    // or undefined (still checking); model is null until a status arrives.
    // Process problems come before the DNS warnings: a running listed process
    // matters more.
    function hero(model, root, applying, graceLeft) {
        if (root === undefined)
            return { verdict: 'verdict.checking', solo: true };
        if (root === false)
            return { verdict: 'verdict.noRoot', cls: 'is-danger', why: 'why.noRoot', solo: true };
        if (root === null || !model)
            return { verdict: 'verdict.noAnswer', cls: 'is-warn', why: 'why.noAnswer', solo: true, retry: 'button.tryAgain' };
        if (applying || model.jobRunning)
            return { verdict: 'verdict.applying', cls: 'is-warn', why: 'why.applying', busy: true };
        if (!model.enabled)
            return { verdict: 'verdict.off', cls: 'is-danger' };
        if (model.anyDirty)
            return { verdict: 'verdict.pending', cls: 'is-warn' };
        if (model.running.length) {
            return { verdict: 'verdict.partial', cls: 'is-danger',
                why: model.running.length > 1 ? 'why.runningMany' : 'why.running', params: { names: model.running } };
        }
        if (model.unknown.length) {
            return { verdict: 'verdict.unverified', cls: 'is-warn', why: 'why.unknown',
                params: { groups: model.unknown }, retry: 'button.checkAgain' };
        }
        if (model.hostsDown) {
            return { verdict: 'verdict.hostsDown', cls: 'is-danger', openLog: true,
                why: model.hostsDown === 'external' ? 'why.hostsOther' : 'why.hostsOff' };
        }
        if (model.dnsDown)
            return { verdict: 'verdict.dnsDown', cls: 'is-warn', why: 'why.dnsDown', openLog: true };
        if (model.ipv4Only)
            return { verdict: 'verdict.ipv4', cls: 'is-warn', why: 'why.ipv4' };
        if (model.sdpWait)
            return { verdict: 'verdict.grace', cls: 'is-warn', why: 'why.grace', params: { seconds: graceLeft } };
        return { verdict: 'verdict.protected', cls: 'is-secure', facts: facts(model) };
    }

    function facts(model) {
        var list = [{ key: 'facts.hosts', n: model.blocklist }];
        if (model.live['dns.filter'])
            list.push({ key: 'facts.dns' });
        if (model.stopped)
            list.push({ key: 'facts.processes', n: model.stopped });
        model.groups.forEach(function (g) {
            (g.kept || []).forEach(function (k) {
                list.push({ key: k.claimed ? 'facts.claimed' : 'facts.kept', n: k.name, params: { apps: k.apps } });
            });
        });
        return list;
    }

    // One status cell: a setting the TV is running with is on; a warning
    // overrides that; a saved change not yet applied is outlined.
    function cell(model, key, graceLeft) {
        var c = { cls: model.live[key] ? 'on' : '', key: 'cell.' + key };
        if (key === 'domains.sdp' && model.live[key] && model.sdpWait) {
            c.cls = 'warn';
            c.key = 'cell.sdpWait';
            c.params = { seconds: graceLeft };
        }
        if (model.hostsDown && model.live[key] && key.indexOf('domains.') === 0)
            c.cls = 'warn';
        if (key === 'dns.filter' && model.dnsDown)
            c.cls = 'warn';
        if (key === 'dns.disable_ipv6') {
            // What the TV runs with when protection is on, else what is saved.
            var off = model.enabled ? model.live[key] : model.saved[key];
            c.key = off ? 'cell.ipv6Off' : 'cell.ipv6On';
            if (model.ipv4Only)
                c.cls = 'warn';
        }
        if (model.dirty[key])
            c.cls += ' pend';
        return c;
    }

    // The line under a service group, in the hero and on its card.
    function groupLine(group) {
        if (group.dirty)
            return { cls: 'c-warn', key: group.saved ? 'state.stopsOnApply' : 'state.restartsOnApply' };
        if (!group.live)
            return { key: 'state.off' };
        if (group.running.length)
            return { cls: 'c-bad', key: 'state.running', params: { names: group.running } };
        if (group.unknown.length)
            return { cls: 'c-warn', key: 'state.unknown' };
        return { key: 'state.stopped' };
    }

    // What the main button does now.
    function mainAction(model) {
        if (!model || !model.enabled)
            return { key: 'button.enable', cls: '', command: 'enable', label: 'Enable protection' };
        if (model.anyDirty)
            return { key: 'button.update', cls: 'pending', command: 'apply', label: 'Update protection' };
        return { key: 'button.disable', cls: 'danger', command: 'disable', label: 'Disable protection' };
    }

    // "n of total" for a rail category's toggles, by saved setting.
    function onCount(model, keys) {
        return { n: keys.filter(function (k) { return model.saved[k]; }).length, total: keys.length };
    }

    // The services rail dot: a fault in what the TV is running.
    function serviceFault(model) {
        if (!model || !model.enabled || model.anyDirty)
            return '';
        return model.running.length ? 'bad' : (model.unknown.length ? 'warn' : '');
    }

    return {
        read: read,
        hero: hero,
        cell: cell,
        groupLine: groupLine,
        mainAction: mainAction,
        onCount: onCount,
        serviceFault: serviceFault
    };
})();
