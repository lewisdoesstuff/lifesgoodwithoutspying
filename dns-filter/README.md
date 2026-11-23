# Local DNS filter helper

This directory contains the optional on-TV DNS filtering helper.

The helper is a small DNS proxy:

- it listens for UDP and TCP DNS
- returns NXDOMAIN for names in the supplied blocklist
- forwards other queries to the configured upstream resolver
- uses only Node core modules in the generated bundle

## Build and test

From the repository root:

```sh
cd dns-filter
bun install
bun run check
bun test
bun run build
bun run smoke
```

The production bundle is written to `dist/nospy-dns-filter.js` as CommonJS.
The bundle is lowered to ES5 so that it also runs on Node 0.12 (webOS 3.x), not
just Node 8.12 (webOS 4-6); `src/buffer.ts` covers the Buffer APIs that Node
0.12 lacks. `bun test` exercises the source; `bun run smoke` also exercises the
generated bundle, its blocklist reload confirmation, and UDP/TCP forwarding.
Set `NOSPY_DNS_NODE` to run the bundle under another Node binary, as CI does
for 0.12.18 and 8.12.0.

## Run

The listener defaults to `127.0.0.2:5353` so that it does not accidentally take
over DNS during development. Binding to port 53 as root must be requested
explicitly:

```sh
node dist/nospy-dns-filter.js \
  --listen-address 127.0.0.2 \
  --listen-port 5353 \
  --upstream 192.168.1.1:53 \
  --blocklist /path/to/generated-blocklist.txt
```

To use the app's generated hosts file directly, select the marker-aware
parser:

```sh
node dist/nospy-dns-filter.js \
  --listen-address 127.0.0.2 \
  --listen-port 5353 \
  --upstream 192.168.1.1:53 \
  --blocklist /var/lib/webosbrew/lifesgoodwithoutspying.hosts \
  --blocklist-format hosts
```

In `hosts` mode, only `0.0.0.0` and `::` entries after the app's generation
marker are used. The original `localhost` and other system aliases are ignored.
If the marker is missing, the helper exits with an error rather than falling
back to an empty allow-all list.

The TV handoff uses the app's canonical domain list file instead:
`/var/lib/webosbrew/lifesgoodwithoutspying.dns`. The app replaces this file
atomically, and it starts with a generation header and a declared rule count,
for example:

```text
# lifesgoodwithoutspying dns-filter generation 1720000000-123 rules 2
ads.example.test
telemetry.example.test
```

The helper writes the generation ID and rule count that it loaded to its status
file. `tv-handoff.sh reload` waits for that confirmation. If a new file is
malformed, incomplete, or does not match its declared rule count, the helper
keeps the previous blocklist active.

Use `--upstream '[2001:db8::1]:53'` for an IPv6 upstream. `--log-blocked`
enables blocked-name logging; it is off by default because query names can be
sensitive.

For the TV handoff, run the reload command after atomically replacing the
domain list file:

```sh
scripts/tv-handoff.sh reload
```

Sending `SIGHUP` directly still works for manual use, but only
`tv-handoff.sh reload` waits for the helper to confirm whether the reload
succeeded. If a reload fails, the helper logs the error and keeps the previous
blocklist active.

In the default `domains` format, blocklist files contain one domain per line.
Blank lines and `#` comments are ignored. Plain names match exactly;
`*.example.com` also matches subdomains. In `hosts` mode, the marker-aware
parser extracts the app-generated sink entries instead. Do not include QuickSet
unless that protection is intentionally enabled.

## Locally blocked DNS replies

A locally blocked name receives a minimal NXDOMAIN reply. If a query carries a
single empty EDNS(0) OPT record with no flags, the helper includes a fresh
empty OPT record in the reply. Other locally generated responses omit EDNS
information, including DNS COOKIEs and DNSSEC-related data. A client that
requires a COOKIE can discard a blocked response, and the helper does not sign
synthesized denials for DNSSEC validation. This is not a general EDNS
implementation. Direct DNS, encrypted DNS, and applications that use other
resolvers are not covered by the filter.

## TV handoff

`scripts/tv-handoff.sh` is a controlled, reversible handoff for the TV
integration. The app build copies it and the generated bundle into the IPK, and
the app's `dns.filter` setting controls it. It uses host-level iptables NAT
rules to redirect port 53:

- keeps ConnMan listening on `127.0.0.1:53` unchanged;
- optionally disables the service's IPv6 configuration when the app's separate
  `dns.disable_ipv6` switch is on. In that mode, it also bind-mounts a
  read-only `resolv.conf` listing only `127.0.0.1`. Otherwise, ConnMan's proxy
  on `::1` keeps forwarding to the IPv6 upstream that it received before IPv6
  was turned off, those queries go unanswered, and the system resolver waits
  out its 5-second timeout on `::1` before every lookup;
- runs the filter on `127.0.0.1:5354`;
- uses NAT to redirect outbound UDP and TCP port-53 queries to that helper, so
  that ConnMan's resolver traffic and all other local DNS queries go through
  the filter;
- exempts the helper's own upstream sockets from redirection by pinning its
  outbound UDP source port to 15354 and rotating its outbound TCP source ports
  across 15355:15483;
- in that same IPv6-off mode, exempts port-53 traffic addressed straight to the
  upstream resolver, because ConnMan's online check uses interface-bound
  sockets that cannot accept the helper's reply over loopback. Apps still reach
  the helper through the replaced `resolv.conf`, although any app that queries
  the upstream address directly will bypass the filter. In the other mode,
  ConnMan's proxy forwards app queries to the upstream, so nothing is exempted
  there;
- restores ConnMan's IPv6 setting and `resolv.conf` and removes the NAT rules
  when you disable the filter. If ConnMan does not report the original value
  back, the handoff keeps its state and helper for a later retry instead of
  reporting that the rollback succeeded.

The script obtains the active ConnMan service, its interface/address, and its
active resolvers from one D-Bus snapshot at runtime. It rejects multiple
active services or multiple IPv4 resolvers rather than guessing. It also stores
only the resolver settings needed for rollback; it does not log or copy Wi-Fi
credentials.

Read-only inspection and a controlled enable/disable test can be run with:

```sh
scripts/tv-handoff.sh plan
scripts/tv-handoff.sh status
sudo scripts/tv-handoff.sh enable
sudo scripts/tv-handoff.sh reload
sudo scripts/tv-handoff.sh disable
```

The app's `dns.filter` setting is off by default. The separate
`dns.disable_ipv6` setting is also off by default and only takes effect while
`dns.filter` is on. When enabled, the apply hook starts or reloads this
handoff; disabling protection or the DNS filter rolls it back. The normal app
build includes the bundle, but does not alter ConnMan until the DNS filter is
explicitly enabled. If IPv6 is preserved, ConnMan may retain an IPv6 DHCP
nameserver and IPv6 DNS can bypass the IPv4 helper.

## Deliberate limitations

The helper filters the requested name, not CNAME targets in the upstream
answer. An allowed name can therefore return an address for a blocked alias
without a separate query for that blocked name. Domain filtering cannot
guarantee that an application will never reach a blocked service.

Locally synthesized errors, including NXDOMAIN replies for blocked names, may
omit the query's EDNS OPT record and its options. In particular, a client that
requires DNS COOKIE responses can discard those replies. This may cause retries
or a lookup failure; it is not evidence that every TV client uses DNS COOKIEs.

The Node helper does not replace ConnMan and is not a firewall by itself. It
cannot block DNS-over-TLS, DNS-over-HTTPS, direct-IP connections, or a process
that uses a custom encrypted resolver. If the helper exits unexpectedly while
enabled, locally generated port-53 queries remain bound to the redirect rules
until the NAT rules are rolled back; this fails closed, but it can cause a DNS
outage. The NAT redirect only covers outbound IPv4 UDP and TCP port 53; IPv6
traffic is not caught by it. The existing hosts mount and executable stubs
remain useful defense-in-depth layers. When stopping the helper, the script
checks that the recorded PID is still running the configured Node executable
and the exact helper bundle before sending a signal. If the helper does not
stop, the script keeps its saved state so that you can retry later. Because
checking the process and sending the signal are separate steps, a small race
condition remains.
