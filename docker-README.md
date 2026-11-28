# is-this-you-icann-resolver

Local ICANN root resolver. Image: `jamesstevens/is-this-you-icann-resolver`.

Unbound on Alpine 3.24 holds `.` as an RFC 8806 local root (`for-downstream: no`, `for-upstream: yes`, `fallback-enabled: yes`). It transfers the zone from `192.0.32.132`, `192.0.47.132`, `192.33.4.12` and `192.5.5.241`, with `zonemd-check: yes` and `zonemd-reject-absence: yes`. Unbound runs as the `unbound` user, chrooted to `/opt/data/unbound`. The zone file is `/opt/data/unbound/root.zone`. The root trust anchor is copied into the chroot at start-up.

Ordinary queries use `rd=1`. Private-range clients have `allow_snoop`, so `rd=0` can return cached data, but not an authoritative (`AA=1`) answer from the auth-zone.

Let's Encrypt `unbound_exporter` v0.6.0 listens on port 9167 and talks to Unbound over `/opt/data/unbound/unbound.ctl`. Unbound is configured with `control-use-cert: no`. The container must be started with `nofile` at least 8192 (`docker run --ulimit nofile=8192:8192`, or the matching Compose `ulimits` on the service).

This container does not terminate TLS. The `icann` mode of [is-this-you-resolver](https://github.com/IsThisYou-org/is-this-you-resolver) runs this image and points `json-doh-proxy` at it. DNS-over-HTTPS is in front of this resolver, not inside it.

Source: [IsThisYou-org/is-this-you-icann-resolver](https://github.com/IsThisYou-org/is-this-you-icann-resolver).

## Ports

- `53/udp` and `53/tcp` — DNS
- `9167/tcp` — Prometheus metrics

Queries are accepted from localhost, `10.0.0.0/8`, `172.16.0.0/12` and `192.168.0.0/16`. Other sources are refused.

## Environment

Logging is syslog only.

- `SYSLOG_SERVER` — forward syslog to that host.
- `SYSLOG_STDOUT=Y` — write syslog to standard output. Ignored when `SYSLOG_SERVER` is set.

When neither is set, logs go to `/opt/data/logs/messages`.

## Run

The root filesystem is read-only. Mount a writable directory on `/opt/data` for the chroot, zone file and logs.

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
