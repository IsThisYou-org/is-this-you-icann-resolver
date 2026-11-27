# is-this-you-icann-resolver

Local ICANN root resolver. Image: `jamesstevens/is-this-you-icann-resolver`.

Unbound on Alpine 3.24 holds `.` as an `auth-zone`. It transfers the zone from `192.0.32.132`, `192.0.47.132`, `192.33.4.12` and `192.5.5.241`, with `zonemd-check: yes`, `for-downstream: yes` and `for-upstream: yes`. DNSSEC validation uses the root trust anchor in the image.

A query with `rd=0` for data in that zone (`. SOA`, `com. DS`) is answered from the zone with `AA=1`. A name below a delegation is a referral.

This container speaks DNS on port 53 only. It does not terminate TLS. The `icann` mode of [is-this-you-resolver](https://github.com/IsThisYou-org/is-this-you-resolver) runs this image and points `json-doh-proxy` at it. DNS-over-HTTPS is in front of this resolver, not inside it.

Source: [IsThisYou-org/is-this-you-icann-resolver](https://github.com/IsThisYou-org/is-this-you-icann-resolver).

## Ports

- `53/udp` and `53/tcp` — DNS

Queries are accepted from localhost, `10.0.0.0/8`, `172.16.0.0/12` and `192.168.0.0/16`. Other sources are refused.

## Environment

Logging is syslog only.

- `SYSLOG_SERVER` — forward syslog to that host.
- `SYSLOG_STDOUT=Y` — write syslog to standard output. Ignored when `SYSLOG_SERVER` is set.

When neither is set, logs go to `/opt/data/logs/messages`.

## Run

The root filesystem is read-only. Mount a writable directory on `/opt/data` for the zone file (`root.zone`) and logs.

```bash
mkdir -p data
docker run --rm --read-only \
  --name is-this-you-icann-resolver \
  -p 53:53/tcp -p 53:53/udp \
  -v "$(pwd)/data:/opt/data" \
  jamesstevens/is-this-you-icann-resolver
```
