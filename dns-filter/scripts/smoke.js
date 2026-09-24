'use strict';

const childProcess = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const bundle = path.join(__dirname, '..', 'dist', 'nospy-dns-filter.js');
const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'nospy-dns-filter-'));
const blocklistPath = path.join(temporaryDirectory, 'blocklist.txt');

try {
  fs.writeFileSync(
    blocklistPath,
    [
      '127.0.0.1 localhost localhost.localdomain',
      '# lifesgoodwithoutspying - blocked LG ad/ACR/telemetry endpoints generation 1-2',
      '0.0.0.0 example.test',
      ':: sdp.example.test',
    ].join('\n') + '\n',
  );
  const result = childProcess.spawnSync(
    process.execPath,
    [
      bundle,
      '--upstream',
      '127.0.0.1:53',
      '--blocklist',
      blocklistPath,
      '--blocklist-format',
      'hosts',
      '--check',
    ],
    { encoding: 'utf8' },
  );

  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error('bundle check failed: ' + (result.stderr || result.stdout));
  }
  if (result.stdout.indexOf('2 blocklist rule(s)') === -1) {
    throw new Error('unexpected bundle output: ' + result.stdout);
  }

  console.log('node smoke test passed');
} finally {
  try {
    fs.unlinkSync(blocklistPath);
  } catch (_error) {
    // The temporary directory is best-effort cleanup.
  }
  try {
    fs.rmdirSync(temporaryDirectory);
  } catch (_error) {
    // The temporary directory is best-effort cleanup.
  }
}
