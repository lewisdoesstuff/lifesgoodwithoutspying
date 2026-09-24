import { main } from './cli';

export { main } from './cli';
export { Blocklist, loadBlocklist, parseBlocklist, parseHostsBlocklist } from './blocklist';
export type { BlocklistFormat } from './blocklist';
export { parseArgs, parseEndpoint, usage } from './config';
export { DnsFilterProxy } from './proxy';
export { makeNxDomainResponse, normalizeDomain, parseDnsQuery, readDnsName } from './dns';

if (require.main === module) {
  main(process.argv.slice(2));
}
