#!/usr/bin/env node
// Generate the Homebrew Channel package manifest for a built IPK.
// Field layout mirrors a real manifest (e.g. org.webosbrew.hbchannel).
// Usage: node scripts/gen-manifest.js <ipk-path> > <id>.manifest.json
const fs = require('fs');
const crypto = require('crypto');

const REPO = 'https://github.com/lewisdoesstuff/lifesgoodwithoutspying';

const ipkPath = process.argv[2];
if (!ipkPath) {
  console.error('usage: gen-manifest.js <ipk-path>');
  process.exit(2);
}

const appinfo = JSON.parse(fs.readFileSync('app/appinfo.json', 'utf8'));
const bytes = fs.readFileSync(ipkPath);
const id = appinfo.id;

const manifest = {
  id: id,
  version: appinfo.version,
  type: appinfo.type,
  title: appinfo.title,
  appDescription: 'Switches off LG TV surveillance: ad delivery, ACR and always-on voice capture.',
  iconUri: REPO.replace('github.com', 'raw.githubusercontent.com') + '/main/app/largeIcon.png',
  sourceUrl: REPO,
  rootRequired: true,
  ipkUrl: REPO + '/releases/latest/download/' + id + '.ipk',
  ipkHash: { sha256: crypto.createHash('sha256').update(bytes).digest('hex') }
};

process.stdout.write(JSON.stringify(manifest, null, 2) + '\n');
