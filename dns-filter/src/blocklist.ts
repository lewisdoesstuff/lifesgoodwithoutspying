import { isIP } from 'net';
import { readFileSync } from 'fs';
import { normalizeDomain } from './dns';

export type BlocklistFormat = 'domains' | 'hosts';

export interface BlockRule {
  domain: string;
  includeSubdomains: boolean;
}

export interface BlocklistMetadata {
  generation: string;
  declaredRuleCount: number | null;
}

export interface ParsedBlocklist {
  rules: string[];
  metadata: BlocklistMetadata;
}

const GENERATION_HEADER_PREFIX = '# lifesgoodwithoutspying dns-filter generation';
const GENERATION_HEADER = /^#\s*lifesgoodwithoutspying dns-filter generation ([A-Za-z0-9._-]+) rules ([0-9]+)\s*$/;

export class Blocklist {
  private readonly exact = new Set<string>();
  private readonly subdomains: string[] = [];
  private readonly metadataValue: BlocklistMetadata;

  constructor(rules: string[], metadata: BlocklistMetadata = {
    generation: 'unknown',
    declaredRuleCount: null,
  }) {
    this.metadataValue = metadata;
    for (const rule of rules) {
      const parsed = parseBlockRule(rule);
      this.add(parsed);
    }
  }

  add(rule: BlockRule): void {
    if (rule.includeSubdomains) {
      if (this.subdomains.indexOf(rule.domain) === -1) {
        this.subdomains.push(rule.domain);
      }
    } else if (!this.exact.has(rule.domain)) {
      this.exact.add(rule.domain);
    }
  }

  replace(rules: string[]): void {
    const exact = new Set<string>();
    const subdomains: string[] = [];

    for (const rule of rules) {
      const parsed = parseBlockRule(rule);
      if (parsed.includeSubdomains) {
        if (subdomains.indexOf(parsed.domain) === -1) {
          subdomains.push(parsed.domain);
        }
      } else if (!exact.has(parsed.domain)) {
        exact.add(parsed.domain);
      }
    }

    this.exact.clear();
    for (const domain of exact) {
      this.exact.add(domain);
    }
    this.subdomains.length = 0;
    for (const domain of subdomains) {
      this.subdomains.push(domain);
    }
  }

  isBlocked(name: string): boolean {
    const domain = normalizeDomain(name);
    if (domain === '') {
      return false;
    }

    if (this.exact.has(domain)) {
      return true;
    }

    for (const suffix of this.subdomains) {
      if (domain.length > suffix.length + 1 && domain.slice(-(suffix.length + 1)) === '.' + suffix) {
        return true;
      }
    }

    return false;
  }

  get size(): number {
    return this.exact.size + this.subdomains.length;
  }

  get metadata(): BlocklistMetadata {
    return this.metadataValue;
  }
}

function parseBlockRule(input: string): BlockRule {
  let value = input.trim();
  let includeSubdomains = false;

  if (value.slice(0, 2) === '*.') {
    includeSubdomains = true;
    value = value.slice(2);
  } else if (value.charAt(0) === '.') {
    includeSubdomains = true;
    value = value.slice(1);
  }

  const domain = normalizeDomain(value);
  if (domain === '' || value.indexOf('*') !== -1) {
    throw new Error('invalid blocklist domain: ' + input);
  }

  return { domain, includeSubdomains };
}

function parseDomainLine(line: string): string {
  const fields = line.trim().split(/\s+/);
  let candidate = fields[0];
  if (isIP(candidate) !== 0 && fields.length > 1) {
    candidate = fields[1];
  }

  // Validate now so a typo cannot silently disable one protection rule.
  parseBlockRule(candidate);
  return candidate;
}

/**
 * Parse a domain artifact, including the optional generation header emitted by
 * the TV init hook. The declared count is checked before the rules are exposed
 * to the proxy, so a syntactically valid but incomplete generation is rejected.
 */
export function parseBlocklistDocument(contents: string): ParsedBlocklist {
  const rules: string[] = [];
  let generation = 'unknown';
  let declaredRuleCount: number | null = null;
  let sawHeader = false;
  const lines = contents.split(/\r?\n/);

  for (let index = 0; index < lines.length; index += 1) {
    let line = lines[index].replace(/\s+#.*$/, '').trim();
    if (line.indexOf(GENERATION_HEADER_PREFIX) === 0) {
      const match = GENERATION_HEADER.exec(line);
      if (match === null || sawHeader) {
        throw new Error('invalid or duplicate DNS generation header');
      }
      sawHeader = true;
      generation = match[1];
      declaredRuleCount = Number(match[2]);
      continue;
    }
    if (line === '' || line.charAt(0) === '#') {
      continue;
    }

    rules.push(parseDomainLine(line));
  }

  if (declaredRuleCount !== null && declaredRuleCount !== rules.length) {
    throw new Error(
      'DNS generation rule count mismatch: declared ' + declaredRuleCount +
        ', parsed ' + rules.length,
    );
  }

  return {
    rules,
    metadata: { generation, declaredRuleCount },
  };
}

/**
 * Parse a small, deliberately boring blocklist format. Plain entries are
 * exact matches; a leading `*.` (or `.`) opts into subtree matching.
 * Hosts-style lines such as `0.0.0.0 example.com` are accepted as a
 * convenience for existing generated lists.
 */
export function parseBlocklist(contents: string): string[] {
  return parseBlocklistDocument(contents).rules;
}

interface HostsGeneration {
  start: number;
  id: string;
}

function findHostsGeneration(lines: string[]): HostsGeneration | null {
  let found: HostsGeneration | null = null;
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index].trim();
    if (line.indexOf('# lifesgoodwithoutspying') !== 0) {
      continue;
    }
    const match = /\bgeneration\s+([A-Za-z0-9._-]+)/.exec(line);
    if (match !== null) {
      found = { start: index, id: match[1] };
    }
  }
  return found;
}

/**
 * Extract only the sink entries written by this app from a generated hosts
 * file. The file also contains the system's original hosts entries, so parsing
 * every line would incorrectly block localhost and unrelated aliases.
 *
 * The last generation marker is selected so a stale marker copied into the
 * underlying file cannot hide the current generation. SDP entries appended
 * after that marker are included as well.
 */
export function parseHostsBlocklistDocument(contents: string): ParsedBlocklist {
  const lines = contents.split(/\r?\n/);
  const generation = findHostsGeneration(lines);
  if (generation === null) {
    throw new Error('generated hosts marker not found');
  }

  const domains: string[] = [];
  for (let index = generation.start + 1; index < lines.length; index += 1) {
    const line = lines[index].replace(/\s+#.*$/, '').trim();
    if (line === '' || line.charAt(0) === '#') {
      continue;
    }

    const fields = line.split(/\s+/);
    if (fields[0] !== '0.0.0.0' && fields[0] !== '::') {
      continue;
    }
    if (fields.length < 2) {
      throw new Error('malformed generated hosts entry: ' + line);
    }

    for (const domain of fields.slice(1)) {
      parseBlockRule(domain);
      domains.push(domain);
    }
  }

  return {
    rules: domains,
    metadata: {
      generation: generation.id,
      declaredRuleCount: null,
    },
  };
}

export function parseHostsBlocklist(contents: string): string[] {
  return parseHostsBlocklistDocument(contents).rules;
}

export function loadBlocklist(path: string, format: BlocklistFormat = 'domains'): Blocklist {
  const contents = readFileSync(path, 'utf8');
  if (format === 'hosts') {
    const parsed = parseHostsBlocklistDocument(contents);
    return new Blocklist(parsed.rules, parsed.metadata);
  }
  if (format === 'domains') {
    const parsed = parseBlocklistDocument(contents);
    return new Blocklist(parsed.rules, parsed.metadata);
  }
  throw new Error('unsupported blocklist format: ' + format);
}
