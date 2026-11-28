#! /bin/sh
# Full-stack QA for a live is-this-you-icann-resolver (and, when present,
# the icann / tls-icann Compose stack).
#
# This script never starts, rebuilds or pushes containers. It only probes
# whatever is already running.
#
# Usage:
#   ./qa.sh
#   DNS_HOST=127.0.0.6 ./qa.sh
#
# Exit status is non-zero if any check FAILs. SKIP is not a failure.
#
# Environment (defaults in parentheses):
#   DNS_HOST (127.0.0.1)   DNS_PORT (53)
#   METRICS_HOST (127.0.0.1)  METRICS_PORT (9167)  METRICS_PATH (/metrics)
#   DOH_URL (http://127.0.0.1:8080)  TLS_URL (unset)
#   CONTAINER_NAME (is-this-you-icann-resolver)
#   ROOT_SERVER (199.7.83.42, L-root)
#   RD0_EXPECT (auto|referral|refused)
#   WAIT_FOR_ZONE (30)  ZONE_MAX_AGE_SECS (172800)  SOA_SERIAL_MAX_DELTA (2)
#   SKIP_DOCKER, SKIP_DOH, SKIP_METRICS, REQUIRE_DOH

set -eu

DNS_HOST=${DNS_HOST:-127.0.0.1}
DNS_PORT=${DNS_PORT:-53}
METRICS_HOST=${METRICS_HOST:-127.0.0.1}
METRICS_PORT=${METRICS_PORT:-9167}
METRICS_PATH=${METRICS_PATH:-/metrics}
DOH_URL=${DOH_URL:-http://127.0.0.1:8080}
TLS_URL=${TLS_URL:-}
CONTAINER_NAME=${CONTAINER_NAME:-is-this-you-icann-resolver}
ROOT_SERVER=${ROOT_SERVER:-199.7.83.42}
CHROOT_DIR=${CHROOT_DIR:-/opt/data/unbound}
ZONEFILE=${ZONEFILE:-/opt/data/unbound/root.zone}
CONTROL_SOCK=${CONTROL_SOCK:-/opt/data/unbound/unbound.ctl}
TRUST_ANCHOR=${TRUST_ANCHOR:-/opt/data/unbound/trusted-key.key}
LOG_FILE=${LOG_FILE:-/opt/data/logs/messages}
ZONE_MAX_AGE_SECS=${ZONE_MAX_AGE_SECS:-172800}
SOA_SERIAL_MAX_DELTA=${SOA_SERIAL_MAX_DELTA:-2}
WAIT_FOR_ZONE=${WAIT_FOR_ZONE:-30}
DIG_TIME=${DIG_TIME:-5}
DIG_TRIES=${DIG_TRIES:-2}
RD0_EXPECT=${RD0_EXPECT:-auto}
SKIP_DOCKER=${SKIP_DOCKER:-0}
SKIP_DOH=${SKIP_DOH:-0}
SKIP_METRICS=${SKIP_METRICS:-0}
REQUIRE_DOH=${REQUIRE_DOH:-0}

passed=0
failed=0
skipped=0
CONTAINER=
DIG_OUT=

pass() {
	passed=$((passed + 1))
	printf 'PASS  %s\n' "$*"
}

fail() {
	failed=$((failed + 1))
	printf 'FAIL  %s\n' "$*"
}

skip() {
	skipped=$((skipped + 1))
	printf 'SKIP  %s\n' "$*"
}

need_cmd() {
	if ! command -v "$1" >/dev/null 2>&1
	then
		printf 'ERROR  required command not found: %s\n' "$1" >&2
		exit 2
	fi
}

# Remaining arguments are the qname, qtype and any extra dig options.
# Recursion, transport, DNSSEC and the AD bit are always passed explicitly.
dig_query() {
	_rd=$1
	_tcp=$2
	_dnssec=$3
	_ad=$4
	shift 4
	dig @"${DNS_HOST}" -p "${DNS_PORT}" \
		+time="${DIG_TIME}" +tries="${DIG_TRIES}" \
		"${_rd}" "${_tcp}" "${_dnssec}" "${_ad}" \
		+nocmd +nostats \
		"$@"
}

dig_rec() {
	dig_query +rec +notcp +dnssec +adflag "$@"
}

dig_norec() {
	dig_query +norec +notcp +dnssec +adflag "$@"
}

dig_rec_tcp() {
	dig_query +rec +tcp +dnssec +adflag "$@"
}

# Store stdout+stderr in DIG_OUT. Return 0 if dig exited 0.
# The wrappers call the dig_* functions directly so the bodies stay
# reachable for shellcheck (they are not invoked via "$@").
run_rec() {
	if DIG_OUT=$(dig_rec "$@" 2>&1)
	then
		return 0
	fi
	return 1
}

run_norec() {
	if DIG_OUT=$(dig_norec "$@" 2>&1)
	then
		return 0
	fi
	return 1
}

run_rec_tcp() {
	if DIG_OUT=$(dig_rec_tcp "$@" 2>&1)
	then
		return 0
	fi
	return 1
}

dig_header_status() {
	printf '%s\n' "$1" | awk '
		/status:/ {
			if (match($0, /status:[[:space:]]*[A-Z]+/)) {
				s = substr($0, RSTART, RLENGTH)
				sub(/status:[[:space:]]*/, "", s)
				print s
				exit
			}
		}
	'
}

dig_header_flags() {
	printf '%s\n' "$1" | awk '
		/flags:/ {
			if (match($0, /flags:[[:space:]]*[^;]*/)) {
				s = substr($0, RSTART, RLENGTH)
				sub(/flags:[[:space:]]*/, "", s)
				print s
				exit
			}
		}
	'
}

flags_has() {
	_flags=$1
	_tok=$2
	printf '%s\n' "${_flags}" | awk -v t="${_tok}" '
		BEGIN { n = split($0, a, /[[:space:]]+/); rc = 1 }
		END {
			for (i = 1; i <= n; i++) if (a[i] == t) rc = 0
			exit rc
		}
	'
}

dig_count_field() {
	_label=$1
	_text=$2
	printf '%s\n' "${_text}" | awk -v lab="${_label}" '
		{
			pat = lab ":[[:space:]]*[0-9]+"
			if (match($0, pat)) {
				s = substr($0, RSTART, RLENGTH)
				sub(/.*:[[:space:]]*/, "", s)
				print s
				exit
			}
		}
	'
}

dig_soa_serial() {
	printf '%s\n' "$1" | awk '
		$4 == "SOA" { print $7; exit }
		$3 == "SOA" { print $6; exit }
	'
}

http_body() {
	printf '%s\n' "$1" | awk 'NR > 1 { print prev } { prev = $0 }'
}

http_code() {
	printf '%s\n' "$1" | awk 'END { print }'
}

have_docker() {
	if test "${SKIP_DOCKER}" != "0"
	then
		return 1
	fi
	command -v docker >/dev/null 2>&1
}

resolve_container() {
	if ! have_docker
	then
		return 1
	fi
	if test -n "${CONTAINER}"
	then
		return 0
	fi
	if docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1
	then
		CONTAINER=${CONTAINER_NAME}
		return 0
	fi
	_found=$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | awk '
		$1 == "is-this-you-icann-resolver" { print $1; exit }
		$2 ~ /is-this-you-icann-resolver/ { print $1; exit }
	')
	if test -n "${_found}"
	then
		CONTAINER=${_found}
		return 0
	fi
	return 1
}

dexec() {
	docker exec "${CONTAINER}" "$@"
}

container_running() {
	have_docker || return 1
	docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q true
}

need_cmd dig
need_cmd awk

printf 'QA    target DNS %s:%s  metrics %s:%s  container %s\n' \
	"${DNS_HOST}" "${DNS_PORT}" "${METRICS_HOST}" "${METRICS_PORT}" \
	"${CONTAINER_NAME}"
printf 'QA    DoH %s  TLS %s  RD0_EXPECT=%s  WAIT_FOR_ZONE=%ss\n' \
	"${DOH_URL}" "${TLS_URL:-unset}" "${RD0_EXPECT}" "${WAIT_FOR_ZONE}"

if have_docker
then
	if resolve_container
	then
		printf 'QA    using container %s\n' "${CONTAINER}"
	else
		printf 'QA    no container named %s (and no image match)\n' \
			"${CONTAINER_NAME}"
	fi
	for _c in json-doh-proxy easy-nginx handshake-volume-resolver \
		handshake-full-node ethereum-dns-gateway
	do
		if container_running "${_c}"
		then
			printf 'QA    also running: %s\n' "${_c}"
		fi
	done
	if container_running handshake-volume-resolver
	then
		printf 'QA    note: handshake-volume-resolver is up; host port 53 may be dnsdist, not Unbound\n'
	fi
else
	if test "${SKIP_DOCKER}" != "0"
	then
		printf 'QA    docker checks disabled (SKIP_DOCKER=%s)\n' "${SKIP_DOCKER}"
	else
		printf 'QA    docker not on PATH; container checks will be skipped\n'
	fi
fi

# Wait until a recursive query answers, so a freshly started stack can
# finish its root AXFR before the checks run.
if test "${WAIT_FOR_ZONE}" -gt 0
then
	printf 'QA    waiting up to %ss for the resolver to answer\n' "${WAIT_FOR_ZONE}"
	_elapsed=0
	while test "${_elapsed}" -lt "${WAIT_FOR_ZONE}"
	do
		if run_rec google.com A
		then
			_st=$(dig_header_status "${DIG_OUT}")
			_ans=$(dig_count_field ANSWER "${DIG_OUT}")
			if test "${_st}" = "NOERROR" && test "${_ans:-0}" -gt 0
			then
				printf 'QA    resolver answering after %ss\n' "${_elapsed}"
				break
			fi
		fi
		sleep 2
		_elapsed=$((_elapsed + 2))
	done
	if test "${_elapsed}" -ge "${WAIT_FOR_ZONE}"
	then
		printf 'QA    wait timed out after %ss (continuing with the checks)\n' \
			"${WAIT_FOR_ZONE}"
	fi
fi

# ---------------------------------------------------------------------------
# DNS checks
# ---------------------------------------------------------------------------

# Root SOA serial, compared to a public root. rd=0 may be REFUSED when
# for-downstream is no, so we fall back to a recursive query.
_serial=
if run_norec . SOA
then
	_st=$(dig_header_status "${DIG_OUT}")
	_serial=$(dig_soa_serial "${DIG_OUT}")
else
	_st=$(dig_header_status "${DIG_OUT}")
	_serial=
fi
if test "${_st}" = "REFUSED" || test -z "${_serial}"
then
	if run_rec . SOA
	then
		_st=$(dig_header_status "${DIG_OUT}")
		_serial=$(dig_soa_serial "${DIG_OUT}")
	else
		_st=$(dig_header_status "${DIG_OUT}")
		_serial=$(dig_soa_serial "${DIG_OUT}")
	fi
fi
if test "${_st}" != "NOERROR" || test -z "${_serial}"
then
	fail "root SOA: expected NOERROR with a serial from ${DNS_HOST}:${DNS_PORT}, got status=${_st:-empty} serial='${_serial}'"
else
	if _pubout=$(dig @"${ROOT_SERVER}" +norec +notcp +dnssec +adflag \
		+time="${DIG_TIME}" +tries="${DIG_TRIES}" +nocmd +nostats . SOA 2>&1)
	then
		_pserial=$(dig_soa_serial "${_pubout}")
		if test -z "${_pserial}"
		then
			fail "root SOA: public root ${ROOT_SERVER} returned no serial"
		else
			_delta=$((_pserial - _serial))
			if test "${_delta}" -lt 0
			then
				_delta=$((-_delta))
			fi
			if test "${_delta}" -le "${SOA_SERIAL_MAX_DELTA}"
			then
				pass "root SOA serial ${_serial} matches ${ROOT_SERVER} (${_pserial}), delta=${_delta}"
			else
				fail "root SOA serial ${_serial} differs from ${ROOT_SERVER} (${_pserial}) by ${_delta}; max delta ${SOA_SERIAL_MAX_DELTA}"
			fi
		fi
	else
		fail "root SOA: could not query public root ${ROOT_SERVER} (status: $(dig_header_status "${_pubout}"))"
	fi
fi

# rd=0 for a TLD. Master has for-downstream: no (RFC 8806), so REFUSED
# is the expected Unbound behaviour when the name is not cached.
# allow_snoop can still return a cached NOERROR. RD0_EXPECT=auto reads
# the running config when it can, and expects a referral when
# for-downstream is yes.
_expect=${RD0_EXPECT}
if test "${_expect}" = "auto"
then
	_expect=refused
	if resolve_container
	then
		_conf=$(dexec sh -c 'cat /usr/local/etc/unbound.conf' 2>/dev/null || true)
		_fd=$(printf '%s\n' "${_conf}" | awk '
			$1 == "for-downstream:" { print $2; exit }
		')
		if test "${_fd}" = "yes"
		then
			_expect=referral
		fi
	fi
	printf 'QA    RD0_EXPECT=auto -> %s\n' "${_expect}"
fi

run_norec com. NS || true
_st=$(dig_header_status "${DIG_OUT}")
_flags=$(dig_header_flags "${DIG_OUT}")
_ans=$(dig_count_field ANSWER "${DIG_OUT}")
_auth=$(dig_count_field AUTHORITY "${DIG_OUT}")
_ans=${_ans:-0}
_auth=${_auth:-0}
if test "${_expect}" = "refused"
then
	if test "${_st}" = "REFUSED"
	then
		pass "rd=0 com. NS is REFUSED (expected with for-downstream: no)"
	elif test "${_st}" = "NOERROR" && test "${_ans}" -gt 0
	then
		pass "rd=0 com. NS is NOERROR with answers (flags: ${_flags})"
	elif test "${_st}" = "NOERROR" && test "${_auth}" -gt 0
	then
		pass "rd=0 com. NS is a referral (flags: ${_flags})"
	else
		fail "rd=0 com. NS: expected REFUSED (for-downstream: no) or a referral, got status=${_st} flags='${_flags}' answer=${_ans} authority=${_auth}"
	fi
elif test "${_st}" = "REFUSED"
then
	fail "rd=0 com. NS was REFUSED (for-downstream is probably no; set RD0_EXPECT=refused if that is intended)"
elif test "${_st}" != "NOERROR"
then
	fail "rd=0 com. NS: expected a referral or in-zone NOERROR, got status=${_st}"
elif test "${_ans}" -eq 0 && test "${_auth}" -eq 0
then
	fail "rd=0 com. NS: NOERROR but no answer or authority records"
elif flags_has "${_flags}" aa && test "${_ans}" -gt 0
then
	pass "rd=0 com. NS is an in-zone AA answer (flags: ${_flags})"
else
	pass "rd=0 com. NS is a referral and not REFUSED (flags: ${_flags} authority=${_auth})"
fi

# rd=1 google.com must be a real answer, not a TLD referral.
# A referral here is the bug a live recursive test is meant to catch.
run_rec google.com A || true
_st=$(dig_header_status "${DIG_OUT}")
_flags=$(dig_header_flags "${DIG_OUT}")
_ans=$(dig_count_field ANSWER "${DIG_OUT}")
_ans=${_ans:-0}
_auth=$(dig_count_field AUTHORITY "${DIG_OUT}")
_auth=${_auth:-0}
if test "${_st}" = "NOERROR" && test "${_ans}" -eq 0 && test "${_auth}" -gt 0
then
	fail "rd=1 google.com A returned a referral, not an answer (the referral bug); flags='${_flags}' authority=${_auth}"
elif test "${_st}" != "NOERROR" || test "${_ans}" -eq 0
then
	fail "rd=1 google.com A: expected NOERROR with answers, got status=${_st} answer=${_ans} flags='${_flags}'"
else
	pass "rd=1 google.com A is NOERROR with ${_ans} answer(s) (flags: ${_flags})"
fi

# AD flag on a well-known signed name. google.com is not signed.
_name=cloudflare.com
run_rec "${_name}" A || true
_st=$(dig_header_status "${DIG_OUT}")
_flags=$(dig_header_flags "${DIG_OUT}")
_ans=$(dig_count_field ANSWER "${DIG_OUT}")
_ans=${_ans:-0}
if test "${_st}" != "NOERROR" || test "${_ans}" -eq 0
then
	fail "+dnssec ${_name} A: expected NOERROR with answers, got status=${_st} answer=${_ans}"
elif flags_has "${_flags}" ad
then
	pass "+dnssec ${_name} A has the AD flag (flags: ${_flags})"
else
	fail "+dnssec ${_name} A: AD flag not set (flags: '${_flags}'); DNSSEC validation may be broken"
fi

# dnssec-failed.org is published with a broken chain.
run_rec dnssec-failed.org A || true
_st=$(dig_header_status "${DIG_OUT}")
if test "${_st}" = "SERVFAIL"
then
	pass "rd=1 dnssec-failed.org A is SERVFAIL (validating resolver)"
else
	fail "rd=1 dnssec-failed.org A: expected SERVFAIL, got status=${_st:-empty}"
fi

run_rec_tcp google.com A || true
_st=$(dig_header_status "${DIG_OUT}")
_ans=$(dig_count_field ANSWER "${DIG_OUT}")
_ans=${_ans:-0}
if test "${_st}" = "NOERROR" && test "${_ans}" -gt 0
then
	pass "TCP rd=1 google.com A is NOERROR with ${_ans} answer(s)"
else
	fail "TCP rd=1 google.com A: expected NOERROR with answers, got status=${_st} answer=${_ans}"
fi

# ---------------------------------------------------------------------------
# Container / filesystem / logs
# ---------------------------------------------------------------------------
if ! resolve_container
then
	skip "unbound user / chroot / zone / logs: no running container"
else
	if _cc=$(dexec /usr/sbin/unbound-checkconf /usr/local/etc/unbound.conf 2>&1)
	then
		pass "unbound-checkconf accepts /usr/local/etc/unbound.conf"
	else
		fail "unbound-checkconf failed: ${_cc}"
	fi

	_ps=$(dexec sh -c 'ps w 2>/dev/null || ps' 2>/dev/null || true)
	_unbound_line=$(printf '%s\n' "${_ps}" | awk '
		/unbound-checkconf/ { next }
		/unbound_exporter/ { next }
		$2 == "unbound" && $0 ~ /\/unbound|[ \t]unbound([ \t]|$)/ { print; exit }
	')
	_root_unbound=$(printf '%s\n' "${_ps}" | awk '
		/unbound-checkconf/ { next }
		/unbound_exporter/ { next }
		$2 == "root" && $0 ~ /\/usr\/sbin\/unbound|[ \t]unbound -d/ { print; exit }
	')
	if test -n "${_unbound_line}"
	then
		pass "unbound runs as user unbound: ${_unbound_line}"
	elif test -n "${_root_unbound}"
	then
		fail "unbound is still running as root: ${_root_unbound}"
	else
		fail "could not find an unbound daemon in the process table"
		printf '%s\n' "${_ps}" | sed 's/^/      /'
	fi

	if dexec sh -c "test -d '${CHROOT_DIR}'"
	then
		pass "chroot directory ${CHROOT_DIR} exists"
	else
		fail "chroot directory ${CHROOT_DIR} is missing"
	fi

	if dexec sh -c "test -s '${TRUST_ANCHOR}'"
	then
		pass "trust anchor ${TRUST_ANCHOR} exists and is non-empty"
	else
		fail "trust anchor ${TRUST_ANCHOR} is missing or empty"
	fi

	if dexec sh -c "test -S '${CONTROL_SOCK}'"
	then
		pass "control socket ${CONTROL_SOCK} exists"
	else
		fail "control socket ${CONTROL_SOCK} is missing (exporter will not be able to talk to Unbound)"
	fi

	if ! dexec sh -c "test -s '${ZONEFILE}'"
	then
		fail "root.zone ${ZONEFILE} is missing or empty (AXFR may not have completed)"
	else
		_meta=$(dexec sh -c "
			if stat -c '%U %G %s %Y' '${ZONEFILE}' >/dev/null 2>&1
			then
				stat -c '%U %G %s %Y' '${ZONEFILE}'
			else
				ls -l '${ZONEFILE}'
			fi
		" 2>/dev/null || true)
		_owner=$(printf '%s\n' "${_meta}" | awk 'NF == 4 { print $1; exit }')
		_group=$(printf '%s\n' "${_meta}" | awk 'NF == 4 { print $2; exit }')
		_size=$(printf '%s\n' "${_meta}" | awk 'NF == 4 { print $3; exit }')
		_mtime=$(printf '%s\n' "${_meta}" | awk 'NF == 4 { print $4; exit }')
		if test -n "${_owner}" && test "${_owner}" != "unbound"
		then
			fail "root.zone owner is ${_owner}, expected unbound (${ZONEFILE})"
		elif test "${_owner}" = "unbound"
		then
			pass "root.zone exists, owned by ${_owner}:${_group}, size=${_size}"
		else
			pass "root.zone exists and is non-empty (${ZONEFILE})"
		fi
		_now=$(date +%s)
		if test -n "${_mtime}" && test -n "${_now}"
		then
			_age=$((_now - _mtime))
			if test "${_age}" -lt 0
			then
				_age=0
			fi
			if test "${_age}" -le "${ZONE_MAX_AGE_SECS}"
			then
				pass "root.zone is recent (age ${_age}s, limit ${ZONE_MAX_AGE_SECS}s)"
			else
				fail "root.zone is stale (age ${_age}s, limit ${ZONE_MAX_AGE_SECS}s)"
			fi
		fi
	fi

	# SYSLOG_STDOUT=Y (dkrun) -> docker logs. Unset (Compose icann) ->
	# /opt/data/logs/messages. SYSLOG_SERVER forwards elsewhere.
	_logs=$(docker logs "${CONTAINER}" 2>&1 || true)
	_filelog=$(dexec sh -c "test -f '${LOG_FILE}' && cat '${LOG_FILE}'" 2>/dev/null || true)
	_alllogs=$(printf '%s\n%s\n' "${_logs}" "${_filelog}")
	if printf '%s\n' "${_alllogs}" | grep -E -q 'setrlimit: Operation not permitted|cannot increase max open fds|continuing with less udp ports'
	then
		fail "logs contain setrlimit / ulimit warnings (raise nofile to 8192 on the container)"
		printf '%s\n' "${_alllogs}" | grep -E 'setrlimit|max open fds|less udp ports|increase ulimit' | sed 's/^/      /'
	elif printf '%s\n' "${_alllogs}" | grep -E -q 'unbound|start_unbound'
	then
		pass "no setrlimit / ulimit warnings in syslog or docker logs"
	else
		skip "no setrlimit warnings seen, but no unbound log lines either (SYSLOG_SERVER may be forwarding them elsewhere)"
	fi
	if printf '%s\n' "${_alllogs}" | grep -E -iq 'zonemd.*(fail|error|mismatch|reject|bad)'
	then
		fail "logs report a ZONEMD problem"
		printf '%s\n' "${_alllogs}" | grep -E -i 'zonemd' | sed 's/^/      /'
	elif printf '%s\n' "${_alllogs}" | grep -E -iq 'zonemd|auth zone \.|auth-zone'
	then
		pass "logs show an auth-zone / ZONEMD load and no ZONEMD error"
	else
		skip "no zonemd / auth-zone lines in the collected logs"
	fi
fi

# ---------------------------------------------------------------------------
# Prometheus exporter
# ---------------------------------------------------------------------------
fetch_metrics() {
	_url="http://${METRICS_HOST}:${METRICS_PORT}${METRICS_PATH}"
	if command -v curl >/dev/null 2>&1
	then
		if curl -fsS --max-time 5 "${_url}" 2>/dev/null
		then
			return 0
		fi
	elif command -v wget >/dev/null 2>&1
	then
		if wget -q -O - --timeout=5 "${_url}" 2>/dev/null
		then
			return 0
		fi
	fi
	if resolve_container
	then
		if dexec sh -c "wget -q -O - --timeout=5 http://127.0.0.1:${METRICS_PORT}${METRICS_PATH}" 2>/dev/null
		then
			return 0
		fi
	fi
	return 1
}

if test "${SKIP_METRICS}" != "0"
then
	skip "exporter metrics (SKIP_METRICS=${SKIP_METRICS})"
else
	if _metrics=$(fetch_metrics)
	then
		_n=$(printf '%s\n' "${_metrics}" | grep -c '^unbound_' || true)
		if test "${_n}" -gt 0
		then
			pass "exporter metrics contain ${_n} unbound_ series"
		else
			fail "metrics endpoint responded but no unbound_ series were present"
		fi
	else
		fail "exporter metrics not reachable at http://${METRICS_HOST}:${METRICS_PORT}${METRICS_PATH} (or via docker exec on 127.0.0.1:${METRICS_PORT}). Compose icann does not publish 9167; dkrun does. Also check control-use-cert and the unix socket."
	fi
fi

# ---------------------------------------------------------------------------
# DoH / TLS front end (icann and tls-icann Compose profiles)
# ---------------------------------------------------------------------------
probe_http_api() {
	_label=$1
	_url=$2
	_tmp=$(curl -sS -L --max-time 10 -o - -w '\n%{http_code}' "${_url}" 2>/dev/null) || true
	_code=$(http_code "${_tmp}")
	_body=$(http_body "${_tmp}")
	if test "${_code}" = "200" && test -n "${_body}"
	then
		pass "${_label} ${_url} returned HTTP 200"
	else
		fail "${_label} ${_url} returned HTTP ${_code:-none}"
	fi
}

if test "${SKIP_DOH}" != "0"
then
	skip "DoH / front-end checks (SKIP_DOH=${SKIP_DOH})"
elif ! command -v curl >/dev/null 2>&1
then
	if test "${REQUIRE_DOH}" != "0"
	then
		fail "DoH checks required but curl is not installed"
	else
		skip "DoH / front-end checks: curl is not installed"
	fi
else
	_doh="${DOH_URL}/dns/api/v1.0/resolv?name=google.com"
	# Reachability gate (no -f: an HTTP error still means the service is up).
	if curl -sS -o /dev/null --max-time 3 "${DOH_URL}/" 2>/dev/null \
		|| curl -sS -o /dev/null --max-time 3 "${_doh}" 2>/dev/null
	then
		probe_http_api "DoH JSON API" "${_doh}"
	elif test "${REQUIRE_DOH}" != "0" || container_running json-doh-proxy
	then
		fail "json-doh-proxy not reachable at ${DOH_URL}"
	else
		skip "json-doh-proxy not reachable at ${DOH_URL} (not required unless REQUIRE_DOH=1)"
	fi
	if test -n "${TLS_URL}"
	then
		probe_http_api "TLS front end" "${TLS_URL}/dns/api/v1.0/resolv?name=google.com"
	elif container_running easy-nginx
	then
		pass "stack service easy-nginx is running"
		skip "easy-nginx is running but TLS_URL is unset (e.g. TLS_URL=https://127.0.0.1)"
	fi
fi

if have_docker
then
	for _c in handshake-full-node ethereum-dns-gateway handshake-volume-resolver
	do
		if container_running "${_c}"
		then
			pass "stack service ${_c} is running"
		fi
	done
fi

printf '\nQA    %s passed, %s failed, %s skipped\n' "${passed}" "${failed}" "${skipped}"
if test "${failed}" -gt 0
then
	exit 1
fi
exit 0
