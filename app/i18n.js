// UI strings and language selection.
//
// Every translatable element carries a data-i18n key (data-i18n-label for an
// aria-label). index.html marks the static ones and app.js marks the rest
// through setText(), so a language change re-renders the page from those
// keys alone. The log stays in English so bug reports stay readable.
//
// Keep one entry per line: tests/test_i18n.py reads this file to check that
// every key used exists and that each language covers the English set.
'use strict';

(function () {
    var STRINGS = {
        en: {
            'button.enable': 'Enable protection',
            'button.update': 'Apply changes',
            'button.disable': 'Disable protection',
            'button.purge': 'Purge unavailable',
            'button.selftest': 'Self-test',
            'button.checkAgain': 'Check again',
            'button.tryAgain': 'Try again',
            'button.openLog': 'Open log',
            'button.language': 'Language: {name}',
            'language.auto': 'Auto',
            'label.logOutput': 'Log output',
            'verdict.checking': 'Checking…',
            'verdict.noRoot': 'Needs root',
            'verdict.noAnswer': 'Homebrew Channel not responding',
            'verdict.applying': 'Applying…',
            'verdict.off': 'Not protected',
            'verdict.pending': 'Changes not applied',
            'verdict.partial': 'Partly protected',
            'verdict.unverified': 'Protected, unverified',
            'verdict.hostsDown': 'Hostnames not blocked',
            'verdict.dnsDown': 'DNS filter not running',
            'verdict.ipv4': 'Protected over IPv4',
            'verdict.grace': 'Nearly protected',
            'verdict.protected': 'Protected',
            'why.noRoot': 'Install and enable the Homebrew Channel, then reopen this app.',
            'why.noAnswer': 'Its service didn\'t answer. It may be restarting.',
            'why.applying': 'This can take a minute on older TVs.',
            'why.running': '{names} is still running.',
            'why.runningMany': '{names} are still running.',
            'why.unknown': 'Couldn\'t check whether the {groups} processes stopped.',
            'why.hostsOff': 'This app\'s hosts file isn\'t in place.',
            'why.hostsOther': 'Another hosts file is mounted over this app\'s.',
            'why.dnsDown': 'It\'s on, but lookups aren\'t going through it yet.',
            'why.ipv4': 'IPv6 lookups can skip the DNS filter.',
            'why.grace': 'LG service platform is blocked in {seconds} s, once the clock is set.',
            'facts.hosts': '{n} hosts blocked',
            'facts.dns': 'DNS filtered',
            'facts.processes': '{n} processes stopped',
            'flash.purged': 'Deleted {n} ACR and voice files.',
            'flash.purgedNone': 'No ACR or voice data to delete.',
            'status.services': 'Services',
            'status.hostnames': 'Hostnames',
            'status.dnsClock': 'DNS & clock',
            'cell.domains.acr': 'ACR',
            'cell.domains.smartad': 'SmartAd',
            'cell.domains.dashboard': 'Home recs',
            'cell.domains.telemetry': 'Telemetry',
            'cell.domains.sdp': 'LG platform',
            'cell.domains.wiselg': 'App usage',
            'cell.domains.thinq': 'ThinQ',
            'cell.domains.lgrecommends': 'Content Store',
            'cell.domains.lgchannels': 'LG Channels',
            'cell.domains.quickset': 'Remote codes',
            'cell.domains.updates': 'Updates',
            'cell.dns.filter': 'DNS filter',
            'cell.ipv6Off': 'IPv6 off',
            'cell.ipv6On': 'IPv6 on',
            'cell.clock.ntp': 'NTP clock',
            'cell.purge.boot': 'Boot purge',
            'cell.sdpWait': 'LG platform in {seconds} s',
            'group.voice': 'Voice',
            'group.ads': 'Ads & ACR',
            'group.thinq': 'ThinQ',
            'group.lan': 'LAN discovery',
            'state.stopped': 'Stopped',
            'state.off': 'Off',
            'state.running': '{names} running',
            'state.unknown': 'Couldn\'t check',
            'state.stopsOnApply': 'Stops on apply',
            'state.restartsOnApply': 'Restarts on apply',
            'rail.hostnames': 'Hostnames',
            'rail.services': 'Services',
            'rail.dnsClock': 'DNS & clock',
            'rail.log': 'Log',
            'rail.count': '{n} of {total}',
            'note.hostnames': 'Blocking a hostname stops uploads to it. It doesn\'t stop the TV collecting data.',
            'heading.optional': 'Optional',
            'item.domains.acr.title': 'ACR / Alphonso',
            'item.domains.acr.detail': 'Content recognition',
            'item.domains.smartad.title': 'SmartAd',
            'item.domains.dashboard.title': 'Home recommendations',
            'item.domains.telemetry.title': 'Telemetry & crash reports',
            'item.domains.sdp.title': 'LG service platform',
            'item.domains.sdp.detail': 'Blocked 60 s after boot so the clock can sync. Turn on NTP in DNS & clock to block it from boot.',
            'item.domains.sdp.detailNtp': 'Blocked from boot. NTP sets the clock.',
            'item.domains.sdp.breaks': 'Breaks Content Store',
            'item.domains.wiselg.title': 'App usage uploads',
            'item.domains.wiselg.breaks': 'Breaks Home previews',
            'item.domains.thinq.title': 'ThinQ',
            'item.domains.thinq.detail': 'Also stops the ThinQ services',
            'item.domains.thinq.svcDetail': 'Also blocks the ThinQ hostnames',
            'item.domains.thinq.breaks': 'Breaks ThinQ app',
            'item.domains.lgrecommends.title': 'Content Store',
            'item.domains.lgrecommends.breaks': 'Breaks Content Store',
            'item.domains.lgchannels.title': 'LG Channels',
            'item.domains.lgchannels.breaks': 'Breaks LG Channels',
            'item.domains.quickset.title': 'Remote code lookup',
            'item.domains.quickset.breaks': 'Breaks Remote setup',
            'item.domains.updates.title': 'Firmware updates',
            'item.domains.updates.breaks': 'Breaks Updates',
            'item.voice.stop.title': 'Voice',
            'item.voice.stop.breaks': 'Breaks Voice button',
            'item.ads.stop.title': 'Ads & ACR',
            'item.lan.block.title': 'LAN discovery',
            'item.lan.block.breaks': 'Breaks Casting',
            'item.dns.filter.title': 'DNS filter',
            'item.dns.filter.detail': 'Catches lookups that skip the hosts file',
            'item.dns.disable_ipv6.title': 'Turn off IPv6',
            'item.dns.disable_ipv6.detail': 'Without this, IPv6 lookups skip the DNS filter',
            'item.clock.ntp.title': 'Set clock from NTP',
            'item.clock.ntp.detail': 'Lets LG\'s service platform be blocked from boot',
            'item.purge.boot.title': 'Purge on boot',
            'item.purge.boot.detail': 'Unavailable until cache paths are verified for this firmware',
            'item.purge.boot.savedOn': 'Unavailable; turn off this saved setting',
            'footer.checking': 'Checking',
            'footer.rooted': 'Rooted',
            'footer.noRoot': 'Not rooted',
            'footer.noAnswer': 'No answer'
        },
        // Russian translation by inchigor (#33).
        ru: {
            'button.enable': 'Включить защиту',
            'button.update': 'Применить изменения',
            'button.disable': 'Выключить защиту',
            'button.purge': 'Очистка недоступна',
            'button.selftest': 'Самопроверка',
            'button.checkAgain': 'Проверить снова',
            'button.tryAgain': 'Повторить',
            'button.openLog': 'Открыть журнал',
            'button.language': 'Язык: {name}',
            'language.auto': 'Авто',
            'label.logOutput': 'Вывод журнала',
            'verdict.checking': 'Проверка…',
            'verdict.noRoot': 'Требуется root',
            'verdict.noAnswer': 'Homebrew Channel не отвечает',
            'verdict.applying': 'Применение…',
            'verdict.off': 'Защита выключена',
            'verdict.pending': 'Изменения не применены',
            'verdict.partial': 'Защита неполная',
            'verdict.unverified': 'Защищено, не проверено',
            'verdict.hostsDown': 'Хосты не блокируются',
            'verdict.dnsDown': 'DNS-фильтр не работает',
            'verdict.ipv4': 'Защищено по IPv4',
            'verdict.grace': 'Почти защищено',
            'verdict.protected': 'Защищено',
            'why.noRoot': 'Установите и включите Homebrew Channel, затем откройте приложение снова.',
            'why.noAnswer': 'Служба не ответила. Возможно, она перезапускается.',
            'why.applying': 'На старых телевизорах это может занять минуту.',
            'why.running': '{names} всё ещё работает.',
            'why.runningMany': '{names} всё ещё работают.',
            'why.unknown': 'Не удалось проверить процессы: {groups}.',
            'why.hostsOff': 'Файл hosts приложения не подключён.',
            'why.hostsOther': 'Поверх файла hosts приложения подключён другой.',
            'why.dnsDown': 'Он включён, но запросы пока через него не проходят.',
            'why.ipv4': 'Запросы по IPv6 могут обходить DNS-фильтр.',
            'why.grace': 'Сервисная платформа LG будет заблокирована через {seconds} с, после установки часов.',
            'facts.hosts': 'Заблокировано хостов: {n}',
            'facts.dns': 'DNS фильтруется',
            'facts.processes': 'Остановлено процессов: {n}',
            'flash.purged': 'Удалено файлов ACR и голоса: {n}.',
            'flash.purgedNone': 'Данных ACR и голоса для удаления нет.',
            'status.services': 'Службы',
            'status.hostnames': 'Хосты',
            'status.dnsClock': 'DNS и часы',
            'cell.domains.acr': 'ACR',
            'cell.domains.smartad': 'SmartAd',
            'cell.domains.dashboard': 'Рекомендации',
            'cell.domains.telemetry': 'Телеметрия',
            'cell.domains.sdp': 'Платформа LG',
            'cell.domains.wiselg': 'Приложения',
            'cell.domains.thinq': 'ThinQ',
            'cell.domains.lgrecommends': 'Магазин',
            'cell.domains.lgchannels': 'LG Channels',
            'cell.domains.quickset': 'Коды пульта',
            'cell.domains.updates': 'Обновления',
            'cell.dns.filter': 'DNS-фильтр',
            'cell.ipv6Off': 'IPv6 выкл.',
            'cell.ipv6On': 'IPv6 вкл.',
            'cell.clock.ntp': 'Часы NTP',
            'cell.purge.boot': 'Очистка',
            'cell.sdpWait': 'Платформа: {seconds} с',
            'group.voice': 'Голос',
            'group.ads': 'Реклама и ACR',
            'group.thinq': 'ThinQ',
            'group.lan': 'Обнаружение в LAN',
            'state.stopped': 'Остановлено',
            'state.off': 'Выкл.',
            'state.running': 'Работает: {names}',
            'state.unknown': 'Не проверено',
            'state.stopsOnApply': 'Остановится при применении',
            'state.restartsOnApply': 'Запустится при применении',
            'rail.hostnames': 'Хосты',
            'rail.services': 'Службы',
            'rail.dnsClock': 'DNS и часы',
            'rail.log': 'Журнал',
            'rail.count': '{n} из {total}',
            'note.hostnames': 'Блокировка хоста останавливает отправку данных на него, но не их сбор телевизором.',
            'heading.optional': 'Дополнительно',
            'item.domains.acr.title': 'ACR / Alphonso',
            'item.domains.acr.detail': 'Распознавание контента',
            'item.domains.smartad.title': 'SmartAd',
            'item.domains.dashboard.title': 'Рекомендации на главном экране',
            'item.domains.telemetry.title': 'Телеметрия и отчёты о сбоях',
            'item.domains.sdp.title': 'Сервисная платформа LG',
            'item.domains.sdp.detail': 'Блокируется через 60 с после загрузки, чтобы часы успели синхронизироваться. Включите NTP в разделе «DNS и часы», чтобы блокировать её сразу.',
            'item.domains.sdp.detailNtp': 'Блокируется сразу после загрузки. Часы ставит NTP.',
            'item.domains.sdp.breaks': 'Ломает магазин',
            'item.domains.wiselg.title': 'Отправка данных об использовании',
            'item.domains.wiselg.breaks': 'Ломает превью Home',
            'item.domains.thinq.title': 'ThinQ',
            'item.domains.thinq.detail': 'Также останавливает службы ThinQ',
            'item.domains.thinq.svcDetail': 'Также блокирует хосты ThinQ',
            'item.domains.thinq.breaks': 'Ломает приложение ThinQ',
            'item.domains.lgrecommends.title': 'Магазин LG',
            'item.domains.lgrecommends.breaks': 'Ломает магазин',
            'item.domains.lgchannels.title': 'LG Channels',
            'item.domains.lgchannels.breaks': 'Ломает LG Channels',
            'item.domains.quickset.title': 'Поиск кодов пульта',
            'item.domains.quickset.breaks': 'Ломает настройку пульта',
            'item.domains.updates.title': 'Обновления прошивки',
            'item.domains.updates.breaks': 'Ломает обновления',
            'item.voice.stop.title': 'Голос',
            'item.voice.stop.breaks': 'Ломает кнопку голоса',
            'item.ads.stop.title': 'Реклама и ACR',
            'item.lan.block.title': 'Обнаружение в LAN',
            'item.lan.block.breaks': 'Ломает трансляцию',
            'item.dns.filter.title': 'DNS-фильтр',
            'item.dns.filter.detail': 'Перехватывает запросы, минующие файл hosts',
            'item.dns.disable_ipv6.title': 'Отключить IPv6',
            'item.dns.disable_ipv6.detail': 'Без этого запросы по IPv6 обходят DNS-фильтр',
            'item.clock.ntp.title': 'Часы по NTP',
            'item.clock.ntp.detail': 'Позволяет блокировать платформу LG сразу после загрузки',
            'item.purge.boot.title': 'Очистка при загрузке',
            'item.purge.boot.detail': 'Недоступно до проверки путей кэша для этой прошивки',
            'item.purge.boot.savedOn': 'Недоступно; отключите сохранённую настройку',
            'footer.checking': 'Проверка',
            'footer.rooted': 'Root есть',
            'footer.noRoot': 'Нет root',
            'footer.noAnswer': 'Нет ответа'
        }
    };
    // Each language names itself, so the switcher stays readable whichever
    // language is showing.
    var NAMES = { en: 'English', ru: 'Русский' };
    var SETTING_KEY = 'nospy-language';
    var SYSTEM_KEY = 'nospy-system-locale';

    function has(obj, key) {
        return Object.prototype.hasOwnProperty.call(obj, key);
    }
    function load(key) {
        try {
            return window.localStorage.getItem(key);
        }
        catch (e) {
            return null;
        }
    }
    function save(key, value) {
        try {
            window.localStorage.setItem(key, value);
        }
        catch (e) { }
    }
    // 'ru-RU', 'ru_RU' and 'ru' all map to 'ru'; anything unsupported is null.
    function supported(tag) {
        var code = String(tag || '').toLowerCase().split(/[-_]/)[0];
        return has(STRINGS, code) ? code : null;
    }

    // 'auto' follows the TV's menu language. The settings service is the
    // authority, but it answers asynchronously, so start from the last answer
    // it gave and let app.js correct it through setSystemLocale().
    var setting = load(SETTING_KEY);
    if (setting !== 'auto' && !(setting && has(STRINGS, setting)))
        setting = 'auto';
    var systemLocale = (window.PalmSystem && window.PalmSystem.locale) ||
        load(SYSTEM_KEY) || navigator.language || '';
    var lang = 'en';

    function resolve() {
        return setting === 'auto' ? (supported(systemLocale) || 'en') : setting;
    }
    // Missing translations fall back to English, so they show untranslated
    // rather than as a raw key.
    function t(key, params) {
        var s = has(STRINGS[lang], key) ? STRINGS[lang][key] :
            (has(STRINGS.en, key) ? STRINGS.en[key] : key);
        if (params) {
            s = s.replace(/\{(\w+)\}/g, function (m, name) {
                return has(params, name) ? params[name] : m;
            });
        }
        return s;
    }
    // A newline in a string becomes a <br>; everything else stays text.
    function fill(el, text) {
        var parts = text.split('\n');
        while (el.firstChild)
            el.removeChild(el.firstChild);
        for (var i = 0; i < parts.length; i++) {
            if (i)
                el.appendChild(document.createElement('br'));
            el.appendChild(document.createTextNode(parts[i]));
        }
    }
    // Params are kept on the element, so a language change re-renders
    // "{seconds} s" with the same values.
    function setText(el, key, params) {
        if (!el)
            return;
        el.setAttribute('data-i18n', key);
        if (params)
            el.setAttribute('data-i18n-params', JSON.stringify(params));
        else
            el.removeAttribute('data-i18n-params');
        fill(el, t(key, params));
    }
    function apply() {
        var i, nodes;
        document.documentElement.lang = lang;
        nodes = document.querySelectorAll('[data-i18n]');
        for (i = 0; i < nodes.length; i++) {
            var params = nodes[i].getAttribute('data-i18n-params');
            fill(nodes[i], t(nodes[i].getAttribute('data-i18n'), params ? JSON.parse(params) : null));
        }
        nodes = document.querySelectorAll('[data-i18n-label]');
        for (i = 0; i < nodes.length; i++)
            nodes[i].setAttribute('aria-label', t(nodes[i].getAttribute('data-i18n-label')));
        var btn = document.getElementById('btn-language');
        if (btn) {
            btn.textContent = t('button.language', {
                name: setting === 'auto' ? t('language.auto') : NAMES[setting]
            });
        }
    }
    function update() {
        lang = resolve();
        apply();
        // app.js re-renders what it builds from status in the new language.
        document.dispatchEvent(new Event('nospy-language-change'));
    }
    // Auto, then each language in turn.
    function cycle() {
        var order = ['auto'].concat(Object.keys(STRINGS));
        setting = order[(order.indexOf(setting) + 1) % order.length];
        save(SETTING_KEY, setting);
        update();
    }
    function setSystemLocale(tag) {
        if (!tag)
            return;
        save(SYSTEM_KEY, tag);
        if (tag === systemLocale)
            return;
        systemLocale = tag;
        if (setting === 'auto')
            update();
    }

    lang = resolve();
    apply();
    window.nospyI18n = { t: t, setText: setText, cycle: cycle, setSystemLocale: setSystemLocale };
})();
