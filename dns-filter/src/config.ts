import { isIP } from 'net';
import type { BlocklistFormat } from './blocklist';

export interface Endpoint {
  host: string;
  port: number;
}

export interface FilterConfig {
  listenAddress: string;
  listenPort: number;
  upstream: Endpoint;
  blocklistPath: string;
  blocklistFormat: BlocklistFormat;
  statusFile?: string;
  timeoutMs: number;
  logBlocked: boolean;
}

export interface ParsedArgs {
  help: boolean;
  check: boolean;
  config?: FilterConfig;
}

export class ConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ConfigError';
  }
}

export function parseEndpoint(value: string, defaultPort = 53): Endpoint {
  const input = value.trim();
  let host: string;
  let portText = '';

  if (input.charAt(0) === '[') {
    const closingBracket = input.indexOf(']');
    if (closingBracket < 2) {
      throw new ConfigError('invalid upstream endpoint: ' + value);
    }

    host = input.slice(1, closingBracket);
    const remainder = input.slice(closingBracket + 1);
    if (remainder !== '') {
      if (remainder.charAt(0) !== ':') {
        throw new ConfigError('invalid upstream endpoint: ' + value);
      }
      portText = remainder.slice(1);
    }
  } else {
    const firstColon = input.indexOf(':');
    const lastColon = input.lastIndexOf(':');
    if (firstColon !== -1 && firstColon === lastColon) {
      host = input.slice(0, lastColon);
      portText = input.slice(lastColon + 1);
    } else {
      host = input;
    }
  }

  if (host === '' || host.indexOf(' ') !== -1) {
    throw new ConfigError('invalid upstream endpoint: ' + value);
  }

  let port = defaultPort;
  if (portText !== '') {
    if (!/^[0-9]+$/.test(portText)) {
      throw new ConfigError('invalid upstream port: ' + portText);
    }
    port = Number(portText);
  }

  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new ConfigError('upstream port must be between 1 and 65535');
  }

  return { host, port };
}

function parsePort(value: string, option: string, allowZero: boolean): number {
  if (!/^[0-9]+$/.test(value)) {
    throw new ConfigError(option + ' must be a number');
  }

  const port = Number(value);
  const minimum = allowZero ? 0 : 1;
  if (!Number.isInteger(port) || port < minimum || port > 65535) {
    throw new ConfigError(option + ' must be between ' + minimum + ' and 65535');
  }
  return port;
}

function parseTimeout(value: string): number {
  if (!/^[0-9]+$/.test(value)) {
    throw new ConfigError('--timeout must be a number of milliseconds');
  }

  const timeout = Number(value);
  if (!Number.isInteger(timeout) || timeout < 100 || timeout > 60000) {
    throw new ConfigError('--timeout must be between 100 and 60000 milliseconds');
  }
  return timeout;
}

function takeValue(args: string[], index: number, option: string): { value: string; next: number } {
  const value = args[index + 1];
  if (value === undefined || value.slice(0, 2) === '--') {
    throw new ConfigError(option + ' requires a value');
  }
  return { value, next: index + 1 };
}

export function parseArgs(args: string[]): ParsedArgs {
  let listenAddress = '127.0.0.2';
  let listenPort = 5353;
  let upstreamText: string | undefined;
  let blocklistPath: string | undefined;
  let blocklistFormat: BlocklistFormat = 'domains';
  let statusFile: string | undefined;
  let timeoutMs = 5000;
  let logBlocked = false;
  let help = false;
  let check = false;

  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    let option = argument;
    let inlineValue: string | undefined;

    const equals = argument.indexOf('=');
    if (argument.slice(0, 2) === '--' && equals > 2) {
      option = argument.slice(0, equals);
      inlineValue = argument.slice(equals + 1);
    }

    if (option === '--help' || option === '-h') {
      help = true;
      continue;
    }

    if (option === '--check') {
      check = true;
      continue;
    }

    if (option === '--log-blocked') {
      logBlocked = true;
      continue;
    }

    let value: string;
    if (inlineValue !== undefined) {
      value = inlineValue;
    } else {
      const taken = takeValue(args, index, option);
      value = taken.value;
      index = taken.next;
    }

    switch (option) {
      case '--listen-address':
        listenAddress = value;
        break;
      case '--listen-port':
        listenPort = parsePort(value, option, true);
        break;
      case '--upstream':
        upstreamText = value;
        break;
      case '--blocklist':
        blocklistPath = value;
        break;
      case '--blocklist-format':
        if (value !== 'domains' && value !== 'hosts') {
          throw new ConfigError('--blocklist-format must be domains or hosts');
        }
        blocklistFormat = value;
        break;
      case '--status-file':
        statusFile = value;
        break;
      case '--timeout':
        timeoutMs = parseTimeout(value);
        break;
      default:
        throw new ConfigError('unknown option: ' + option);
    }
  }

  if (help) {
    return { help: true, check: false };
  }

  if (isIP(listenAddress) === 0) {
    throw new ConfigError('--listen-address must be an IPv4 or IPv6 address');
  }
  if (upstreamText === undefined) {
    throw new ConfigError('--upstream is required');
  }
  if (blocklistPath === undefined || blocklistPath.trim() === '') {
    throw new ConfigError('--blocklist is required');
  }

  return {
    help: false,
    check,
    config: {
      listenAddress,
      listenPort,
      upstream: parseEndpoint(upstreamText),
      blocklistPath,
      blocklistFormat,
      statusFile,
      timeoutMs,
      logBlocked,
    },
  };
}

export function usage(): string {
  return [
    'Usage:',
    '  nospy-dns-filter --upstream HOST[:PORT] --blocklist PATH [options]',
    '',
    'Options:',
    '  --listen-address ADDRESS  Listener address (default: 127.0.0.2)',
    '  --listen-port PORT        Listener port; 0 asks the OS for a test port',
    '                           (default: 5353)',
    '  --upstream HOST[:PORT]   Upstream resolver (default port: 53)',
    '  --blocklist PATH         Domain blocklist file',
    '  --blocklist-format FMT   domains (default) or generated hosts marker',
    '  --status-file PATH       Publish acknowledged reload status atomically',
    '  --timeout MS             Upstream timeout (default: 5000)',
    '  --log-blocked            Log blocked domain names',
    '  --check                  Validate configuration and blocklist, then exit',
    '  -h, --help               Show this help',
  ].join('\n');
}
