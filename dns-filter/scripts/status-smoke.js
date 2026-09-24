'use strict';

const childProcess = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const bundle = path.join(__dirname, '..', 'dist', 'nospy-dns-filter.js');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'nospy-status-'));
const artifact = path.join(directory, 'domains.txt');
const statusFile = path.join(directory, 'status');
fs.writeFileSync(
  artifact,
  '# lifesgoodwithoutspying dns-filter generation smoke-one rules 1\none.example.test\n',
);
const child = childProcess.spawn(process.execPath, [
  bundle,
  '--listen-address', '127.0.0.1',
  '--listen-port', '0',
  '--upstream', '192.0.2.1:53',
  '--blocklist', artifact,
  '--blocklist-format', 'domains',
  '--status-file', statusFile,
], { stdio: ['ignore', 'ignore', 'ignore'] });

let finished = false;

function cleanup() {
  if (finished) {
    return;
  }
  finished = true;
  // The smoke test only needs the process gone; use SIGKILL so a failed
  // cleanup can never leave a listener behind in the test environment.
  child.kill('SIGKILL');
  try { fs.unlinkSync(artifact); } catch (_error) { /* best effort */ }
  try { fs.unlinkSync(statusFile); } catch (_error) { /* best effort */ }
  try { fs.rmdirSync(directory); } catch (_error) { /* best effort */ }
}

function statusValue(key) {
  try {
    const lines = fs.readFileSync(statusFile, 'utf8').split(/\n/);
    for (const line of lines) {
      if (line.indexOf(key + '=') === 0) {
        return line.slice(key.length + 1);
      }
    }
  } catch (_error) {
    return undefined;
  }
  return undefined;
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function waitFor(predicate, description) {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    if (predicate()) {
      return;
    }
    await sleep(100);
  }
  throw new Error('timed out waiting for ' + description);
}

function writeArtifact(name, count, domains) {
  const temporary = artifact + '.next';
  const contents = [
    '# lifesgoodwithoutspying dns-filter generation ' + name + ' rules ' + count,
  ].concat(domains).join('\n') + '\n';
  fs.writeFileSync(temporary, contents);
  fs.renameSync(temporary, artifact);
}

(async function run() {
  await waitFor(() => statusValue('ready') === '1', 'initial helper status');
  if (statusValue('generation') !== 'smoke-one' || statusValue('rules') !== '1') {
    throw new Error('initial generation status mismatch');
  }

  writeArtifact('smoke-two', 2, ['one.example.test', 'two.example.test']);
  child.kill('SIGHUP');
  await waitFor(() => statusValue('reload_sequence') === '1', 'successful reload acknowledgement');
  if (statusValue('reload_ok') !== '1' || statusValue('generation') !== 'smoke-two' || statusValue('rules') !== '2') {
    throw new Error('successful reload status mismatch');
  }

  const malformed = artifact + '.bad';
  fs.writeFileSync(malformed, '# lifesgoodwithoutspying dns-filter generation smoke-bad rules 2\nonly.example.test\n');
  fs.renameSync(malformed, artifact);
  child.kill('SIGHUP');
  await waitFor(() => statusValue('reload_sequence') === '2', 'failed reload acknowledgement');
  if (statusValue('reload_ok') !== '0' || statusValue('generation') !== 'smoke-two' || statusValue('rules') !== '2') {
    throw new Error('failed reload replaced the active generation');
  }

  console.log('status reload smoke passed');
  cleanup();
})().catch((error) => {
  console.error(error.stack || error);
  cleanup();
  process.exitCode = 1;
});
