# is-this-you-icann-resolver

Local copy of the ICANN DNS root, used by Unbound as an RFC 8806 local root. The image name is `jamesstevens/is-this-you-icann-resolver`.

Unbound from Alpine 3.24 holds `.` as an `auth-zone`. It transfers the zone from the ICANN transfer servers `192.0.32.132` (`xfr.lax.dns.icann.org`) and `192.0.47.132` (`xfr.cjr.dns.icann.org`), and from `c.root-servers.net` (`192.33.4.12`) and `f.root-servers.net` (`192.5.5.241`). The transfer is checked with `zonemd-check: yes` and `zonemd-reject-absence: yes`. A zone whose ZONEMD digest does not match, or that has no ZONEMD, is not served. `for-upstream: yes`, `for-downstream: no` and `fallback-enabled: yes` mean Unbound uses that copy for its own lookups and falls back to ordinary recursion if the local zone cannot answer. It does not serve the zone authoritatively to clients.

DNSSEC validation uses the root trust anchor shipped in the image, `/usr/share/dnssec-root/trusted-key.key`. At start-up `start_up` copies that file into the chroot as `/opt/data/unbound/trusted-key.key`. Unbound itself runs as the `unbound` user, chrooted to `/opt/data/unbound`. The zone file is `/opt/data/unbound/root.zone`.

The container speaks DNS on port 53. It does not terminate TLS, and it does not serve DNS-over-HTTPS. Logging is syslog only. Let's Encrypt `unbound_exporter` v0.6.0 listens on port 9167 and scrapes Unbound over a Unix control socket at `/opt/data/unbound/unbound.ctl`. Unbound is configured with `control-use-cert: no`, so that socket does not require a client certificate.

## Recursion and `rd=0`

Ordinary client queries should have the recursion-desired bit set (`rd=1`). Unbound resolves them using the local root for the first hop:

```
dig @127.0.0.1 +rec +dnssec +adflag google.com A
```

Access control on the private ranges is `allow_snoop`, so a query with `rd=0` can return data already in the cache. Because `for-downstream` is `no`, Unbound does not serve the auth-zone to clients, and those `rd=0` answers are not authoritative (`AA=1`) from this copy of the root. An `rd=0` query for something that is not cached is typically REFUSED.

```
dig @127.0.0.1 +norec +dnssec +adflag com. NS
```

## Used by the `icann` mode of is-this-you-resolver

The `icann` profile of [is-this-you-resolver](https://github.com/IsThisYou-org/is-this-you-resolver) runs this image as the service and container `is-this-you-icann-resolver`, at `172.30.53.60` on the resolver network. In that mode `json-doh-proxy` sets both `DOH_SERVERS` and `LOCAL_ICANN_ROOT` to `172.30.53.60`. Clients speak DoH to `json-doh-proxy`. This container is the DNS server behind it.

This repository builds the image. It does not push it.

## Ports

| Port | Use |
| --- | --- |
| `53/udp` | DNS |
| `53/tcp` | DNS, including the zone transfer Unbound makes outbound |
| `9167/tcp` | Prometheus metrics from `unbound_exporter` |

There is no TLS listener.

Unbound accepts queries from `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12` and `192.168.0.0/16`. Every other source is refused. A normal Docker bridge address falls inside `172.16.0.0/12`, so publishing port 53 to the host works. IPv6 is off.

## Environment

| Variable | Effect |
| --- | --- |
| `SYSLOG_SERVER` | When set, `syslogd` forwards to that host (`-R`) and does not write a local file. |
| `SYSLOG_STDOUT` | Set to `Y` to write syslog to standard output (`-O -`). Ignored when `SYSLOG_SERVER` is set. |

When neither is set, `syslogd` appends `/opt/data/logs/messages`, with nine rotations of 100000 bytes.

## File descriptors

Unbound tries to raise its own file-descriptor limit at start-up. In a container that is not permitted, so the limit has to be set from the outside. Use at least 8192, or Unbound logs a `setrlimit: Operation not permitted` warning and runs with fewer UDP ports.

Docker run:

```
docker run --ulimit nofile=8192:8192 ...
```

Compose, on the service (not at the top level):

```
ulimits:
  nofile:
    soft: 8192
    hard: 8192
```

`./dkrun` already passes `--ulimit nofile=8192:8192`.

## Run

The root filesystem is read-only. `/run` and `/tmp` point at `/dev/shm`. The chroot, zone file, control socket and log directory need a writable mount on `/opt/data`. Unbound stores the zone at `/opt/data/unbound/root.zone`.

```bash
mkdir -p data
docker run --rm --read-only \
  --name is-this-you-icann-resolver \
  --ulimit nofile=8192:8192 \
  -p 53:53/tcp -p 53:53/udp \
  -p 127.0.0.1:9167:9167 \
  -v "$(pwd)/data:/opt/data" \
  jamesstevens/is-this-you-icann-resolver
```

`./dkrun` is the lab wrapper: the same ulimit, `SYSLOG_STDOUT=Y`, DNS on `127.0.0.6` and `192.168.1.146`, and metrics on `9167`. It runs the image `is-this-you-icann-resolver` and mounts `/opt/data/is-this-you-icann-resolver` on `/opt/data`. It does not set `--name`.

To watch logs on the console instead of the file:

```bash
docker run --rm --read-only \
  --name is-this-you-icann-resolver \
  --ulimit nofile=8192:8192 \
  -e SYSLOG_STDOUT=Y \
  -p 53:53/tcp -p 53:53/udp \
  -p 127.0.0.1:9167:9167 \
  -v "$(pwd)/data:/opt/data" \
  jamesstevens/is-this-you-icann-resolver
```

The entry point is `/usr/local/bin/start_up`. It creates `/opt/data/logs` and `/opt/data/unbound`, copies the trust anchor into the chroot, sets ownership to `unbound`, and then execs `/sbin/init`. `/etc/inittab` respawns `start_syslogd`, `start_unbound` and `start_unbound_exporter`. Each of those scripts ends in `exec`. If start-up fails (`unbound-checkconf`, or the log directory cannot be created), the script runs `exec sleep 30` so init can respawn it.

The host needs outbound DNS to the four transfer addresses above. Until the zone is loaded, lookups that need the root use the fallback path rather than the local copy.

## Build

`./dkmk` writes the build stamp and builds the image named in `list`:

```bash
date +%Y%m%d.%H%M > build.txt
docker image build -t "$(cat list)" .
```

The builder stage is `golang:1.27.4-alpine3.24` and installs Let's Encrypt `unbound_exporter` v0.6.0 as a static binary. `build.txt` is copied into the image as `/usr/local/etc/build.txt`. It is listed in `.gitignore`. Do not commit it. `./dkmk` does not push the image.

## QA

`./qa.sh` probes a running container. It does not build, start or push anything. `dig` (BIND) is required.

```bash
./qa.sh
DNS_HOST=127.0.0.6 ./qa.sh
```
