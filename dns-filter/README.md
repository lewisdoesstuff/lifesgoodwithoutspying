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
Vite targets ES2015 because webOS 5/6 provide Node 8.12. `bun test` exercises
the source; `bun run smoke` also exercises the generated bundle and its
acknowledged blocklist-reload protocol.

## Run

The listener defaults to `127.0.0.2:5353` to avoid accidentally taking over
ConnMan's `127.0.0.1:53` during development. Port 53 and a root listener are
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

## TV handoff prototype

`scripts/tv-handoff.sh` is a controlled, reversible prototype for the TV
integration. The app build copies it and the generated bundle into the IPK;
the `dns.filter` app setting controls it. On the tested webOS 9 TV,
ConnMan's resolver sockets bind their upstream sockets to `wlan0`, so using
`127.0.0.2` as ConnMan's upstream does not work reliably. The tested handoff
instead:

- keeps ConnMan listening on `127.0.0.1:53`;
- runs the filter on the TV's current IPv4 address;
- changes the active ConnMan service's configured IPv4 nameserver to that
  address;
- optionally disables the service's IPv6 configuration when the app's separate
  `dns.disable_ipv6` companion switch is on;
- installs a temporary IPv4 firewall chain to prevent LAN clients from using
  the TV's DNS listener;
- restores the previous nameserver and, only if it changed it, IPv6 setting;
  removes the firewall chain on disable. If ConnMan does not report the
  original values back, the handoff keeps its state/helper for a later retry
  instead of claiming a successful rollback.

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

The Node helper does not replace ConnMan and is not a firewall by itself. It
cannot block DNS-over-TLS, DNS-over-HTTPS, direct-IP connections, or a process
that uses a custom encrypted resolver. If the helper exits unexpectedly while
enabled, ConnMan remains pointed at the local listener until the handoff is
re-applied or rolled back; this fails closed but can cause a DNS outage. The
handoff script's temporary firewall chain only protects the TV listener from
LAN clients in the tested IPv4 path. The existing hosts mount and executable
stubs remain useful defense-in-depth layers.