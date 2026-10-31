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
The bundle is lowered to ES5 so it also runs on Node 0.12 (webOS 3.x), not
just Node 8.12 (webOS 4-6); `src/buffer.ts` covers the Buffer APIs Node 0.12
lacks. `bun test` exercises the source; `bun run smoke` also exercises the
generated bundle, its acknowledged blocklist-reload protocol, and UDP/TCP
forwarding. Set `NOSPY_DNS_NODE` to run the bundle under another Node binary,
as CI does for 0.12.18 and 8.12.0.

## Run

The listener defaults to `127.0.0.2:5353` to avoid accidentally taking over
during development. Port 53 and a root listener are
intentionally explicit:

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
A missing marker is an error rather than an empty allow-all list.

The TV handoff uses the app's canonical artifact instead:
`/var/lib/webosbrew/lifesgoodwithoutspying.dns`. It is atomically replaced and
contains a generation header plus the declared rule count, for example:

```text
# lifesgoodwithoutspying dns-filter generation 1720000000-123 rules 2
ads.example.test
telemetry.example.test
```

The helper publishes the successfully loaded generation and counts to its
status file. `tv-handoff.sh reload` waits for that acknowledgement; malformed,
partial, or count-mismatched generations leave the previous blocklist active.

Use `--upstream '[2001:db8::1]:53'` for an IPv6 upstream. `--log-blocked`
enables blocked-name logging; it is off by default because query names can be
sensitive.

For the TV handoff, use the acknowledged control action after atomically
replacing the canonical artifact:

```sh
scripts/tv-handoff.sh reload
```

A direct `SIGHUP` remains supported for generic/manual use, but only the
handoff action waits for the helper's success/failure status. A failed reload
is logged and the previous blocklist remains active.

In the default `domains` format, blocklist files contain one domain per line.
Blank lines and `#` comments are ignored. Plain names match exactly;
`*.example.com` also matches subdomains. In `hosts` mode, the marker-aware
parser extracts the app-generated sink entries instead. Do not include QuickSet
unless that protection is intentionally enabled.

## Locally blocked DNS replies

A locally blocked name receives a minimal NXDOMAIN. For a single empty
EDNS(0) OPT without flags, the helper includes a fresh empty OPT in that reply.
Other locally generated responses still omit EDNS information, including DNS
COOKIEs and DNSSEC-related data. A client that requires a COOKIE can discard a
blocked response; DNSSEC validation of synthesized denials is not provided.
This is not a general EDNS implementation. Direct DNS, encrypted DNS and
applications using other resolvers remain outside the filter's coverage.

## TV handoff

`scripts/tv-handoff.sh` is a controlled, reversible handoff for the TV
integration. The app build copies it and the generated bundle into the IPK;
the `dns.filter` app setting controls it. It uses an nftables/iptables-style
port-53 divert at the host level:

- keeps ConnMan listening on `127.0.0.1:53` unchanged;
- optionally disables the service's IPv6 configuration when the app's separate
  `dns.disable_ipv6` companion switch is on. In that mode it also bind-mounts a
  read-only `resolv.conf` listing only `127.0.0.1`: ConnMan's proxy on `::1`
  keeps forwarding to the IPv6 upstream it learned before IPv6 was turned off,
  those queries are never answered, and the system resolver would otherwise
  wait out its 5-second timeout on `::1` before every lookup;
- runs the filter on `127.0.0.1:5354`;
- NATs outbound UDP and TCP port-53 queries to that helper, so ConnMan's
  resolver traffic and every other local DNS attempt is filtered;
- the helper's own upstream sockets are exempted from the divert: its UDP
  upstream source port is pinned to 15354 and its TCP upstream source ports
  rotate across 15355:15483;
- restores ConnMan's IPv6 setting and `resolv.conf` and removes the NAT rules
  on disable. If
  ConnMan does not report the original value back, the handoff keeps its
  state/helper for a later retry instead of claiming a successful rollback.

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

The app's `dns.filter` setting defaults to off. The separate
`dns.disable_ipv6` companion setting also defaults to off and is honored only
while `dns.filter` is on. When enabled, the apply hook starts/reloads this
handoff; disabling protection or the DNS filter runs the rollback path. The
normal app build includes the bundle, but does not alter ConnMan until the
DNS filter is explicitly enabled. If IPv6 is preserved, ConnMan may retain an
IPv6 DHCP nameserver and IPv6 DNS can bypass the IPv4 helper.

## Deliberate limitations

The helper filters the requested name, not CNAME targets in the upstream
answer. An allowed name can therefore return an address for a blocked alias
without a separate query for that blocked name. Domain filtering cannot
establish that an application will not reach a blocked service.

Locally synthesized errors, including blocked-name NXDOMAIN replies, may omit the
query's EDNS OPT record and its options. In particular, a client that requires
DNS COOKIE responses can discard those replies. This may cause retries or a
lookup failure; it is not evidence that every TV client uses DNS COOKIEs.

The Node helper does not replace ConnMan and is not a firewall by itself. It
cannot block DNS-over-TLS, DNS-over-HTTPS, direct-IP connections, or a process
that uses a custom encrypted resolver. If the helper exits unexpectedly while
enabled, locally generated port-53 queries remain bound to the redirect rules
until the NAT rules are rolled back; this fails closed but can cause a DNS
outage. The NAT divert only covers outbound IPv4 UDP/TCP port 53; IPv6 traffic
is not caught by it. The existing hosts mount and executable stubs remain
useful defense-in-depth layers.
The stop path verifies that the recorded PID still runs the configured Node
executable and exact helper bundle before signaling it. If the verified helper
does not stop, its state is retained for a later retry. Process inspection and
signaling remain separate operations, so there is still a small race.
