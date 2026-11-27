# is-this-you-icann-resolver

Local copy of the ICANN DNS root, served by Unbound. The image name is `jamesstevens/is-this-you-icann-resolver`.

Unbound from Alpine 3.24 holds `.` as an `auth-zone`. It transfers the zone from the ICANN transfer servers `192.0.32.132` (`xfr.lax.dns.icann.org`) and `192.0.47.132` (`xfr.cjr.dns.icann.org`), and from `c.root-servers.net` (`192.33.4.12`) and `f.root-servers.net` (`192.5.5.241`). The transfer is checked with `zonemd-check: yes`. A zone whose ZONEMD digest does not match is not served. `for-downstream: yes` and `for-upstream: yes` publish that copy to clients and to Unbound's own lookups. DNSSEC validation uses the root trust anchor shipped in the image, `/usr/share/dnssec-root/trusted-key.key`.

The container speaks DNS only. It does not terminate TLS, and it does not serve DNS-over-HTTPS. Logging is syslog only.

## `rd=0` answers with `AA=1`

A query with the recursion-desired bit clear (`rd=0`) for data in the root zone is answered from that copy, with the authoritative-answer bit set (`AA=1`). That includes the root SOA and the delegation data published in the root, such as `com. DS`.

```
dig @127.0.0.1 +norec . SOA
dig @127.0.0.1 +norec com. DS
```

Those responses carry `flags: qr aa` and an answer section, once the zone has loaded.

A query for a name below a delegation is a referral from this copy of the root. The AA bit is clear on that referral. With `for-downstream: yes`, Unbound does not chase the delegation for an `rd=0` query.

`for-downstream: no` makes the same `rd=0` queries REFUSED, with no AA bit. That option stays `yes`.

## Used by the `icann` mode of is-this-you-resolver

The `icann` profile of [is-this-you-resolver](https://github.com/IsThisYou-org/is-this-you-resolver) runs this image as the service and container `is-this-you-icann-resolver`, at `172.30.53.60` on the resolver network. In that mode `json-doh-proxy` sets both `DOH_SERVERS` and `LOCAL_ICANN_ROOT` to `172.30.53.60`. Clients speak DoH to `json-doh-proxy`. This container is the DNS server behind it.

This repository builds the image. It does not push it.

## Ports

| Port | Use |
| --- | --- |
| `53/udp` | DNS |
| `53/tcp` | DNS, including the zone transfer Unbound makes outbound |

Nothing else is published. There is no TLS listener.

Unbound accepts queries from `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12` and `192.168.0.0/16`. Every other source is refused. A normal Docker bridge address falls inside `172.16.0.0/12`, so publishing port 53 to the host works. IPv6 is off.

## Environment

| Variable | Effect |
| --- | --- |
| `SYSLOG_SERVER` | When set, `syslogd` forwards to that host (`-R`) and does not write a local file. |
| `SYSLOG_STDOUT` | Set to `Y` to write syslog to standard output (`-O -`). Ignored when `SYSLOG_SERVER` is set. |

When neither is set, `syslogd` appends `/opt/data/logs/messages`, with nine rotations of 100000 bytes.

## Run

The root filesystem is read-only. `/run` and `/tmp` point at `/dev/shm`. The zone file and the log directory need a writable mount on `/opt/data`. Unbound stores the zone at `/opt/data/root.zone`.

```bash
mkdir -p data
docker run --rm --read-only \
  --name is-this-you-icann-resolver \
  -p 53:53/tcp -p 53:53/udp \
  -v "$(pwd)/data:/opt/data" \
  jamesstevens/is-this-you-icann-resolver
```

`./dkrun` does the same. It reads the image name from `list` and mounts `./data` on `/opt/data`.

To watch logs on the console instead of the file:

```bash
docker run --rm --read-only \
  --name is-this-you-icann-resolver \
  -e SYSLOG_STDOUT=Y \
  -p 53:53/tcp -p 53:53/udp \
  -v "$(pwd)/data:/opt/data" \
  jamesstevens/is-this-you-icann-resolver
```

The entry point is `/usr/local/bin/start_up`. It creates `/opt/data/logs` and then execs `/sbin/init`. `/etc/inittab` respawns `start_syslogd` and `start_unbound`. Each of those scripts ends in `exec`. If start-up fails (`unbound-checkconf`, or the log directory cannot be created), the script runs `exec sleep 30` so init can respawn it.

The host needs outbound DNS to the four transfer addresses above. Until the zone is loaded, authoritative answers are not available.

## Build

`./dkmk` writes the build stamp, builds the image named in `list`, and removes the stamp from the work tree:

```bash
date +%Y%m%d.%H%M > build.txt
docker image build -t "$(cat list)" .
```

`build.txt` is copied into the image as `/usr/local/etc/build.txt`. It is listed in `.gitignore`. Do not commit it. `./dkmk` does not push the image.
