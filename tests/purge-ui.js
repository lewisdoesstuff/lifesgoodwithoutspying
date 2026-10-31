'use strict';
const fs = require('fs'), vm = require('vm'), assert = require('assert');
const source = fs.readFileSync('app/app.js', 'utf8');
function section(start, end) { return source.slice(source.indexOf(start), source.indexOf(end)); }
const detail = {}, classes = {};
const purge = { disabled: false, classList: { toggle(k, v) { classes[k] = v; } },
    getAttribute() { return 'purge.boot'; }, setAttribute(k, v) { this[k] = v; },
    querySelector() { return detail; } };
const elements = { 'sdp-detail': {}, 'root-dot': {}, 'root-text': {}, 'app-version': {},
    'btn-purge': {}, 'btn-selftest': {}, 'btn-language': {} };
const ui = { root: true, busy: false, model: {saved: {'purge.boot': true}, dirty: {}, groups: []},
    appVersion: '', byId(id) { return elements[id]; },
    each(selector, fn) { if (selector === '.item[data-key]') fn(purge); },
    setText(el, key) { el.key = key; } };
vm.createContext(ui);
vm.runInContext(section('    function renderPanes()', '    // Each category') +
    section('    var ROOT_TEXT', '    function render()'), ui);
ui.renderPanes(); ui.renderFooter();
assert.equal(purge.disabled, false);
assert.equal(purge['aria-checked'], 'true');
assert.equal(detail.key, 'item.purge.boot.savedOn');
assert.equal(elements['btn-purge'].disabled, true);
ui.busy = true; ui.renderPanes(); assert.equal(purge.disabled, true);
ui.busy = false; ui.model.saved['purge.boot'] = false; ui.renderPanes();
assert.equal(purge.disabled, true);
assert.equal(purge['aria-checked'], 'false');
assert.equal(detail.key, 'item.purge.boot.detail');
ui.model.saved['purge.boot'] = true; ui.root = false; ui.renderPanes();
assert.equal(purge.disabled, true);
console.log('Purge UI availability and saved-setting checks passed');
