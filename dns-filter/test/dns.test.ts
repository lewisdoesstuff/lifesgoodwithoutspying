import { describe, expect, it } from 'bun:test';
import { Blocklist, parseBlocklist, parseBlocklistDocument, parseHostsBlocklist } from '../src/blocklist';
import { makeNxDomainResponse, normalizeDomain, parseDnsQuery } from '../src/dns';
import { parseEndpoint } from '../src/config';

function queryFor(name: string, id = 0x1234): Buffer {
  const labels = name.split('.');
  let length = 12 + 1;
  for (const label of labels) {
    length += label.length + 1;
  }
  length += 4;

  const query = Buffer.alloc(length);
  query.writeUInt16BE(id, 0);
  query.writeUInt16BE(0x0100, 2);
  query.writeUInt16BE(1, 4);
  let offset = 12;
  for (const label of labels) {
    query[offset] = label.length;
    offset += 1;
    query.write(label, offset, label.length, 'ascii');
    offset += label.length;
  }
  query[offset] = 0;
  offset += 1;
  query.writeUInt16BE(1, offset);
  query.writeUInt16BE(1, offset + 2);
  return query;
}

describe('DNS wire helpers', () => {
  it('parses a normal query and synthesizes NXDOMAIN with the question intact', () => {
    const query = queryFor('ads.example.test', 0x4321);
    const parsed = parseDnsQuery(query);
    expect(parsed).not.toBeNull();
    expect(parsed?.id).toBe(0x4321);
    expect(parsed?.name).toBe('ads.example.test');
    expect(parsed?.questionCount).toBe(1);

    const response = makeNxDomainResponse(query, parsed!);
    expect(response).not.toBeNull();
    expect(response!.readUInt16BE(0)).toBe(0x4321);
    expect(response!.readUInt16BE(2) & 0x8000).toBe(0x8000);
    expect(response!.readUInt16BE(2) & 0x000f).toBe(3);
    expect(response!.readUInt16BE(4)).toBe(1);
    expect(response!.readUInt16BE(6)).toBe(0);
    expect(response!.slice(12)).toEqual(query.slice(12));
  });

  it('normalizes valid names and rejects malformed names', () => {
    expect(normalizeDomain(' Example.COM. ')).toBe('example.com');
    expect(normalizeDomain('bad name')).toBe('');
    expect(normalizeDomain('bad..example')).toBe('');
    expect(normalizeDomain('')).toBe('');
  });

  it('rejects responses as queries', () => {
    const query = queryFor('example.test');
    query.writeUInt16BE(0x8180, 2);
    expect(parseDnsQuery(query)).toBeNull();
  });
});

describe('blocklist parsing', () => {
  it('supports exact, wildcard, and hosts-style entries', () => {
    const rules = parseBlocklist([
      '# comment',
      'ads.example.test',
      '*.tracking.example.test',
      '0.0.0.0 pixel.example.test',
    ].join('\n'));
    const blocklist = new Blocklist(rules);

    expect(blocklist.isBlocked('ads.example.test')).toBe(true);
    expect(blocklist.isBlocked('ADS.EXAMPLE.TEST.')).toBe(true);
    expect(blocklist.isBlocked('sub.ads.example.test')).toBe(false);
    expect(blocklist.isBlocked('a.tracking.example.test')).toBe(true);
    expect(blocklist.isBlocked('tracking.example.test')).toBe(false);
    expect(blocklist.isBlocked('pixel.example.test')).toBe(true);
    expect(blocklist.isBlocked('example.test')).toBe(false);
  });
});

describe('canonical generation artifacts', () => {
  it('validates the declared rule count before exposing rules', () => {
    const parsed = parseBlocklistDocument([
      '# lifesgoodwithoutspying dns-filter generation 42-7 rules 2',
      'one.example.test',
      'two.example.test',
    ].join('\n'));
    expect(parsed.metadata).toEqual({ generation: '42-7', declaredRuleCount: 2 });
    expect(parsed.rules).toHaveLength(2);
    expect(() => parseBlocklistDocument([
      '# lifesgoodwithoutspying dns-filter generation 42-8 rules 2',
      'one.example.test',
    ].join('\n'))).toThrow();
  });

  it('rejects malformed or duplicate generation headers', () => {
    expect(() => parseBlocklistDocument([
      '# lifesgoodwithoutspying dns-filter generation broken',
      'one.example.test',
    ].join('\n'))).toThrow();
    expect(() => parseBlocklistDocument([
      '# lifesgoodwithoutspying dns-filter generation one rules 1',
      'one.example.test',
      '# lifesgoodwithoutspying dns-filter generation two rules 0',
    ].join('\n'))).toThrow();
  });
});

describe('generated hosts parsing', () => {
  it('extracts only entries after the app generation marker', () => {
    const rules = parseHostsBlocklist([
      '127.0.0.1 localhost localhost.localdomain',
      '# lifesgoodwithoutspying - blocked LG ad/ACR/telemetry endpoints generation 1-2',
      '0.0.0.0 ads.example.test',
      ':: ads.example.test',
      '# lifesgoodwithoutspying - blocked LG ad/ACR/telemetry endpoints SDP clock-sync grace period complete',
      ':: sdp.example.test',
    ].join('\n'));
    const blocklist = new Blocklist(rules);

    expect(blocklist.isBlocked('ads.example.test')).toBe(true);
    expect(blocklist.isBlocked('sdp.example.test')).toBe(true);
    expect(blocklist.isBlocked('localhost')).toBe(false);
    expect(blocklist.isBlocked('localhost.localdomain')).toBe(false);
  });

  it('fails closed when the generated marker is absent', () => {
    expect(() => parseHostsBlocklist('127.0.0.1 localhost')).toThrow();
  });

  it('accepts a marked but empty generation', () => {
    expect(parseHostsBlocklist(
      '# lifesgoodwithoutspying - blocked LG ad/ACR/telemetry endpoints generation empty-1-2',
    )).toEqual([]);
  });
});

describe('blocklist reloading', () => {
  it('replaces rules only after the new list parses successfully', () => {
    const blocklist = new Blocklist(['old.example.test']);
    blocklist.replace(['new.example.test']);
    expect(blocklist.isBlocked('old.example.test')).toBe(false);
    expect(blocklist.isBlocked('new.example.test')).toBe(true);

    expect(() => blocklist.replace(['bad domain'])).toThrow();
    expect(blocklist.isBlocked('new.example.test')).toBe(true);
  });
});

describe('endpoint parsing', () => {
  it('handles IPv4, bare IPv6, and bracketed IPv6 endpoints', () => {
    expect(parseEndpoint('192.0.2.1')).toEqual({ host: '192.0.2.1', port: 53 });
    expect(parseEndpoint('192.0.2.1:5353')).toEqual({ host: '192.0.2.1', port: 5353 });
    expect(parseEndpoint('2001:db8::1')).toEqual({ host: '2001:db8::1', port: 53 });
    expect(parseEndpoint('[2001:db8::1]:5353')).toEqual({ host: '2001:db8::1', port: 5353 });
  });
});
