import { renameSync, unlinkSync, writeFileSync } from 'fs';
import { Blocklist, loadBlocklist } from './blocklist';
import { ParsedArgs, parseArgs, usage } from './config';
import { DnsFilterProxy } from './proxy';

export function main(args: string[]): void {
  let parsed: ParsedArgs;
  try {
    parsed = parseArgs(args);
  } catch (error) {
    fail(error);
    return;
  }

  if (parsed.help) {
    console.log(usage());
    return;
  }

  const config = parsed.config;
  if (config === undefined) {
    fail(new Error('configuration was not produced'));
    return;
  }

  let blocklist: Blocklist;
  try {
    blocklist = loadBlocklist(config.blocklistPath, config.blocklistFormat);
  } catch (error) {
    fail(error);
    return;
  }

  if (parsed.check) {
    const metadata = blocklist.metadata;
    console.log(
      'ok: ' + blocklist.size + ' blocklist rule(s); generation=' + metadata.generation +
        '; declared_rules=' + formatCount(metadata.declaredRuleCount) +
        '; listener ' + config.listenAddress + ':' + config.listenPort +
        '; upstream ' + formatEndpoint(config.upstream.host, config.upstream.port),
    );
    return;
  }

  const proxy = new DnsFilterProxy(config, blocklist, {
    log: (message: string) => console.error('[dns-filter] ' + message),
    error: (error: Error) => console.error('[dns-filter] ' + error.message),
  });
  let reloadSequence = 0;
  publishStatus(config.statusFile, blocklist, false, 0, reloadSequence);

  let stopping = false;
  const stop = () => {
    if (stopping) {
      return;
    }
    stopping = true;
    publishStatus(
      config.statusFile,
      blocklist,
      false,
      1,
      reloadSequence,
    );
    proxy.close(() => process.exit(0));
  };

  process.once('SIGINT', stop);
  process.once('SIGTERM', stop);
  process.on('SIGHUP', () => {
    reloadSequence += 1;
    try {
      const replacement = proxy.reloadBlocklist(config.blocklistPath);
      blocklist = replacement;
      publishStatus(config.statusFile, replacement, true, 1, reloadSequence);
      console.error(
        '[dns-filter] reloaded generation=' + replacement.metadata.generation +
          ' rules=' + replacement.size +
          ' declared_rules=' + formatCount(replacement.metadata.declaredRuleCount),
      );
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      publishStatus(
        config.statusFile,
        blocklist,
        true,
        0,
        reloadSequence,
        message,
      );
      console.error('[dns-filter] blocklist reload failed: ' + message);
    }
  });

  proxy.start((error?: Error) => {
    if (error) {
      publishStatus(config.statusFile, blocklist, false, 0, reloadSequence, error.message);
      console.error('[dns-filter] failed to start: ' + error.message);
      proxy.close(() => {
        process.exitCode = 1;
      });
      return;
    }

    publishStatus(config.statusFile, blocklist, true, 1, reloadSequence);
    console.error(
      '[dns-filter] listening generation=' + blocklist.metadata.generation +
        ' rules=' + blocklist.size +
        ' on ' + config.listenAddress + ':' + proxy.getListenPort() +
        '; forwarding to ' + formatEndpoint(config.upstream.host, config.upstream.port),
    );
  });
}

function publishStatus(
  path: string | undefined,
  blocklist: Blocklist,
  ready: boolean,
  reloadOk: number,
  sequence: number,
  error?: string,
): void {
  if (path === undefined || path === '') {
    return;
  }

  const metadata = blocklist.metadata;
  const lines = [
    'version=1',
    'pid=' + process.pid,
    'ready=' + (ready ? 1 : 0),
    'reload_ok=' + reloadOk,
    'reload_sequence=' + sequence,
    'generation=' + metadata.generation,
    'rules=' + blocklist.size,
    'declared_rules=' + formatCount(metadata.declaredRuleCount),
  ];
  if (error) {
    lines.push('error=' + error.replace(/[\r\n]/g, ' ').slice(0, 240));
  }

  const temporary = path + '.tmp.' + process.pid;
  try {
    writeFileSync(temporary, lines.join('\n') + '\n', { encoding: 'utf8', mode: 0o600 });
    renameSync(temporary, path);
  } catch (writeError) {
    try {
      unlinkSync(temporary);
    } catch (_cleanupError) {
      // Best effort cleanup only.
    }
    console.error('[dns-filter] status update failed: ' + asError(writeError).message);
  }
}

function formatCount(value: number | null): string {
  return value === null ? 'unknown' : String(value);
}

function formatEndpoint(host: string, port: number): string {
  if (host.indexOf(':') !== -1) {
    return '[' + host + ']:' + port;
  }
  return host + ':' + port;
}

function asError(value: any): Error {
  return value instanceof Error ? value : new Error(String(value));
}

function fail(value: any): void {
  const message = value instanceof Error ? value.message : String(value);
  console.error('[dns-filter] ' + message);
  console.error(usage());
  process.exitCode = 1;
}
