#!/usr/bin/env bash
# rtc-test.sh -- WordPress RTC HTTP polling load tester
#
# Two-file package: drop rtc-test.php into mu-plugins, then use this script.
#
# Requirements: bash, curl
# WP-CLI (wp) is used by setup/teardown if available; not needed for test commands.
# python3 is required for the capture-sanitize and replay commands only.
#
# Workflow A -- run everything on the web host (WP-CLI available):
#   bash rtc-test.sh setup
#   bash rtc-test.sh baseline
#   bash rtc-test.sh sustain
#   bash rtc-test.sh teardown
#
# Workflow B -- setup on web host, run tests from localhost:
#   On web host:  bash rtc-test.sh setup
#                 cat .env                   # copy output to clipboard
#   On localhost: paste into .env, then:
#                 bash rtc-test.sh refresh-auth   # re-login from this host
#                 bash rtc-test.sh baseline
#                 bash rtc-test.sh sustain
#   On web host:  bash rtc-test.sh teardown
#
# Commands:
#   setup               Install MU-plugin, create rtctest user + test post, write .env
#   teardown            Delete test post, remove cookie jar, strip generated section from .env
#   baseline            Measure ambient WP REST overhead (run before scenarios)
#   single-idle         1 client, POLLS polls, no updates
#   two-idle            2 clients alternating, awareness propagation check
#   two-editing         2 clients: sync handshake + update exchange (1 pass)
#   one-idle-one-editing 2 clients: 1 editor sends updates, 1 idle watches
#   n-idle              N_CLIENTS clients round-robin, awareness only
#   compaction-trigger  Send updates until should_compact fires, then compact
#   report              Fetch log from plugin and print summary table
#   clear               Delete all log entries (table intact)
#   reset               Drop and recreate the log table

set -euo pipefail

# -------------------------------------------------------------------------
# Config file auto-load
# Source .env (written by setup) before applying defaults so that
# environment variables set by the caller still take precedence.
# -------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# resolve_env_file: prints the path of the active env file.
# Uses .env if it exists, otherwise falls back to .env.example.
resolve_env_file() {
	if [ -f "${SCRIPT_DIR}/.env" ]; then
		printf '%s' "${SCRIPT_DIR}/.env"
	else
		printf '%s' "${SCRIPT_DIR}/.env.example"
	fi
}

_env_file="$(resolve_env_file)"
if [ -f "${_env_file}" ]; then
	# Snapshot any variables the caller already set in the environment so we
	# can restore them after sourcing -- env vars take precedence over the file.
	_pre_url="${WP_URL:-}"
	_pre_user="${WP_USER:-}"
	_pre_pass="${WP_PASS:-}"
	_pre_jar="${WP_COOKIE_JAR:-}"
	_pre_nonce="${WP_NONCE:-}"
	_pre_path="${WP_PATH:-}"
	_pre_post="${POST_ID:-}"
	_pre_approach="${APPROACH:-}"
	_pre_reporter_url="${REPORTER_URL:-}"
	_pre_api_key="${REPORTER_API_KEY:-}"
	_pre_env_name="${ENVIRONMENT_NAME:-}"
	# shellcheck source=/dev/null
	. "${_env_file}"
	[ -n "${_pre_url}"          ] && WP_URL="${_pre_url}"
	[ -n "${_pre_user}"         ] && WP_USER="${_pre_user}"
	[ -n "${_pre_pass}"         ] && WP_PASS="${_pre_pass}"
	[ -n "${_pre_jar}"          ] && WP_COOKIE_JAR="${_pre_jar}"
	[ -n "${_pre_nonce}"        ] && WP_NONCE="${_pre_nonce}"
	[ -n "${_pre_path}"         ] && WP_PATH="${_pre_path}"
	[ -n "${_pre_post}"         ] && POST_ID="${_pre_post}"
	[ -n "${_pre_approach}"     ] && APPROACH="${_pre_approach}"
	[ -n "${_pre_reporter_url}" ] && REPORTER_URL="${_pre_reporter_url}"
	[ -n "${_pre_api_key}"      ] && REPORTER_API_KEY="${_pre_api_key}"
	[ -n "${_pre_env_name}"     ] && ENVIRONMENT_NAME="${_pre_env_name}"
	unset _pre_url _pre_user _pre_pass _pre_jar _pre_nonce _pre_path _pre_post \
	      _pre_approach _pre_reporter_url _pre_api_key _pre_env_name
fi
unset _env_file

# -------------------------------------------------------------------------
# Configuration (all overridable via environment variables or .env)
# -------------------------------------------------------------------------

WP_URL="${WP_URL:-http://localhost}"
WP_USER="${WP_USER:-admin}"
WP_PASS="${WP_PASS:-}"                                            # WP login password (set by setup)
WP_COOKIE_JAR="${WP_COOKIE_JAR:-${SCRIPT_DIR}/rtc-test-cookies.txt}"  # cookie jar path (set by setup)
WP_NONCE="${WP_NONCE:-}"                                          # wp_rest nonce (set by setup, ~12h TTL)
WP_PATH="${WP_PATH:-}"       # Absolute path to WordPress root; required by setup
REQUIRED_WP_VERSION="${REQUIRED_WP_VERSION:-nightly}"   # WordPress version required by these tests
POST_ID="${POST_ID:-1}"
POLLS="${POLLS:-10}"
POLL_DELAY="${POLL_DELAY:-1}"   # Seconds between polls per client (0 = immediate re-poll / stress mode)
N_CLIENTS="${N_CLIENTS:-3}"
DURATION="${DURATION:-30}"      # Seconds to run for sustain command
UPDATE_SIZE="${UPDATE_SIZE:-small}"
APPROACH="${APPROACH:-}"        # Storage approach label (e.g. post-meta, custom-table); written to log
REPORTER_URL="${REPORTER_URL:-https://make.wordpress.org/hosting}"

# -------------------------------------------------------------------------
# Deterministic test constants
# -------------------------------------------------------------------------

# Client IDs are integers (REST schema: minimum 1).
CLIENT_A=10001
CLIENT_B=10002

# Room identifier.
ROOM="postType/post:${POST_ID}"

# Fixed awareness payloads per client (minimal structure).
AWARENESS_A='{"name":"RTC-Test-Client-A","color":"#cc0000"}'
AWARENESS_B='{"name":"RTC-Test-Client-B","color":"#0000cc"}'

# CRDT sync protocol payloads (base64-encoded, opaque to the server).
# The server stores and relays these without CRDT validation.
SYNC_STEP1_DATA="AA=="        # base64 of 0x00 -- minimal Yjs state vector (empty doc)
SYNC_STEP2_DATA="AAAA"        # base64 of 0x00 0x00 0x00 -- minimal sync step 2 response

# Update payloads by size (fixed, so tests are deterministic and reproducible).
# small  = 3 decoded bytes  -- baseline latency
# medium = 384 decoded bytes -- typical edit delta
# large  = 3072 decoded bytes -- large paste / bulk edit
UPDATE_SMALL="AQAB"
# shellcheck disable=SC2016
UPDATE_MEDIUM="$(printf '%0.sAQABAgACAwADBAA' {1..30} | head -c 512)"
# shellcheck disable=SC2016
UPDATE_LARGE="$(printf '%0.sAQABAgACAwADBAA' {1..280} | head -c 4096)"

# Select payload based on UPDATE_SIZE.
case "${UPDATE_SIZE}" in
	medium) UPDATE_DATA="${UPDATE_MEDIUM}" ;;
	large)  UPDATE_DATA="${UPDATE_LARGE}" ;;
	*)      UPDATE_DATA="${UPDATE_SMALL}" ;;
esac

# -------------------------------------------------------------------------
# Identification headers (present on every /wp-sync/ request)
# -------------------------------------------------------------------------
# X-RTC-Test: 1        -- tells the plugin to record this request
# X-RTC-Scenario: <s>  -- labels the scenario in the log
# -b sends cookies read-only (does not save new Set-Cookie headers), which is
# safe for concurrent curl requests since all instances only read the jar.
BASE_CURL_OPTS=(
	--silent
	--show-error
	-b "${WP_COOKIE_JAR}"
	-H "X-WP-Nonce: ${WP_NONCE}"
	-H "X-RTC-Test: 1"
	-H "Content-Type: application/json"
)
[ -n "${APPROACH}" ] && BASE_CURL_OPTS+=( -H "X-RTC-Approach: ${APPROACH}" )

RTC_ENDPOINT="${WP_URL}/wp-json/wp-sync/v1/updates"
PLUGIN_LOG_URL="${WP_URL}/wp-json/rtc-test/v1/log"
PLUGIN_ENV_URL="${WP_URL}/wp-json/rtc-test/v1/env"
PLUGIN_TABLE_URL="${WP_URL}/wp-json/rtc-test/v1/table"
PLUGIN_REPORT_URL="${WP_URL}/wp-json/rtc-test/v1/report"
PLUGIN_REPORT_ALL_URL="${WP_URL}/wp-json/rtc-test/v1/report-all"
PLUGIN_SUBMIT_URL="${WP_URL}/wp-json/rtc-test/v1/submit"

CAPTURE_SESSION_URL="${WP_URL}/wp-json/rtc-capture/v1/session"
CAPTURE_SESSIONS_URL="${WP_URL}/wp-json/rtc-capture/v1/sessions"

# -------------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------------

# die MESSAGE
die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

# require_auth
# Confirms that cookie jar and nonce are available before running a test command.
require_auth() {
	if [ ! -f "${WP_COOKIE_JAR}" ] || [ -z "${WP_NONCE}" ]; then
		die "Auth not configured. Run: bash rtc-test.sh setup"
	fi
}

# do_login USER PASS URL JAR
# Logs in via wp-login.php and saves cookies to JAR.
# Returns 0 if wordpress_logged_in cookie is present in JAR, 1 otherwise.
do_login() {
	local _user="$1" _pass="$2" _url="$3" _jar="$4"
	# GET login page first to seed the test cookie that WP checks on POST.
	curl -s -c "${_jar}" "${_url}/wp-login.php" -o /dev/null
	# POST credentials. rememberme=forever gives a 14-day cookie vs 2-day default.
	curl -s -c "${_jar}" -b "${_jar}" -L -o /dev/null \
		--data-urlencode "log=${_user}" \
		--data-urlencode "pwd=${_pass}" \
		--data "wp-submit=Log+In&redirect_to=%2Fwp-admin%2F&testcookie=1&rememberme=forever" \
		"${_url}/wp-login.php"
	grep -q "wordpress_logged_in" "${_jar}" 2>/dev/null
}

# do_get_nonce URL JAR
# Calls the rtctest_nonce AJAX handler and prints the wp_rest nonce.
# Prints nothing if the call fails (caller should check for empty output).
do_get_nonce() {
	local _url="$1" _jar="$2"
	curl -s -b "${_jar}" -X POST \
		--data "action=rtctest_nonce" \
		"${_url}/wp-admin/admin-ajax.php" \
		| grep -o '"nonce":"[^"]*"' | head -1 | cut -d'"' -f4 || true
}

# rtc_post SCENARIO JSON_BODY
# Posts to the RTC endpoint with the given scenario label.
# Test metadata is sent as both request headers and query parameters so the
# plugin can receive it even when a reverse proxy strips custom headers.
# _wpnonce is sent in the URL as a fallback in case X-WP-Nonce is also stripped.
# Prints the raw response body followed by __HTTP_STATUS__:NNN on its own line.
rtc_post() {
	local scenario="$1"
	local body="$2"
	local url="${RTC_ENDPOINT}?_rtctest=1&_rtcscenario=${scenario}&_wpnonce=${WP_NONCE}"
	[ -n "${APPROACH}" ] && url="${url}&_rtcapproach=${APPROACH}"
	curl "${BASE_CURL_OPTS[@]}" \
		-H "X-RTC-Scenario: ${scenario}" \
		-X POST "${url}" \
		-w '\n__HTTP_STATUS__:%{http_code}' \
		-d "${body}"
}

# rtc_post_timed SCENARIO JSON_BODY
# Same as rtc_post but appends timing breakdown lines measured by curl:
#   __CLIENT_MS__:<total_ms>
#   __CLIENT_TIMING__:<connect_ms>:<tls_ms>:<server_ms>:<transfer_ms>
# where server_ms = time_starttransfer - time_pretransfer (PHP/DB processing only).
rtc_post_timed() {
	local scenario="$1"
	local body="$2"
	local url="${RTC_ENDPOINT}?_rtctest=1&_rtcscenario=${scenario}&_wpnonce=${WP_NONCE}"
	[ -n "${APPROACH}" ] && url="${url}&_rtcapproach=${APPROACH}"
	local timing
	timing=$(curl "${BASE_CURL_OPTS[@]}" \
		-H "X-RTC-Scenario: ${scenario}" \
		-X POST "${url}" \
		-d "${body}" \
		-w '\n__CURL_TIME__:%{time_namelookup}:%{time_connect}:%{time_appconnect}:%{time_pretransfer}:%{time_starttransfer}:%{time_total}' \
		-D /tmp/rtctest_last_headers.txt \
		-o /tmp/rtctest_last_response.json 2>&1) || true
	cat /tmp/rtctest_last_response.json
	# Parse the six timing fields and derive the four useful deltas.
	local ms connect_ms tls_ms server_ms transfer_ms
	ms=$(printf '%s' "${timing}" | grep '__CURL_TIME__' | awk -F: '{
		dns=$2; conn=$3; tls=$4; pre=$5; ttfb=$6; total=$7
		printf "%.0f", total*1000
	}')
	connect_ms=$(printf '%s' "${timing}" | grep '__CURL_TIME__' | awk -F: '{
		printf "%.0f", ($3-$2)*1000
	}')
	tls_ms=$(printf '%s' "${timing}" | grep '__CURL_TIME__' | awk -F: '{
		printf "%.0f", ($4-$3)*1000
	}')
	server_ms=$(printf '%s' "${timing}" | grep '__CURL_TIME__' | awk -F: '{
		printf "%.0f", ($6-$5)*1000
	}')
	transfer_ms=$(printf '%s' "${timing}" | grep '__CURL_TIME__' | awk -F: '{
		printf "%.0f", ($7-$6)*1000
	}')
	printf '\n__CLIENT_MS__:%s\n' "${ms}"
	printf '__CLIENT_TIMING__:%s:%s:%s:%s\n' "${connect_ms}" "${tls_ms}" "${server_ms}" "${transfer_ms}"
}

# extract_cursor RESPONSE_JSON
# Prints the end_cursor value from the first room in the response.
extract_cursor() {
	printf '%s' "$1" | grep -o '"end_cursor":[0-9]*' | head -1 | grep -o '[0-9]*' || true
}

# extract_update_count RESPONSE_JSON
# Prints the total_updates value from the first room in the response.
extract_update_count() {
	printf '%s' "$1" | grep -o '"total_updates":[0-9]*' | head -1 | grep -o '[0-9]*' || true
}

# extract_should_compact RESPONSE_JSON
# Prints "true" or "false".
extract_should_compact() {
	printf '%s' "$1" | grep -o '"should_compact":\(true\|false\)' | head -1 | grep -o '\(true\|false\)' || true
}

# extract_client_ms TIMED_RESPONSE
# Prints total elapsed ms from rtc_post_timed output.
extract_client_ms() {
	printf '%s' "$1" | grep '__CLIENT_MS__' | grep -o '[0-9]*$'
}

# extract_server_ms TIMED_RESPONSE
# Prints server processing ms (TTFB - pretransfer) from rtc_post_timed output.
# This is PHP+DB time only, with network and TLS removed.
extract_server_ms() {
	printf '%s' "$1" | grep '__CLIENT_TIMING__' | awk -F: '{print $4}'
}

# extract_connect_ms TIMED_RESPONSE
# Prints TCP connect ms. Near-zero means loopback; >5ms means real network.
extract_connect_ms() {
	printf '%s' "$1" | grep '__CLIENT_TIMING__' | awk -F: '{print $2}'
}

# extract_tls_ms TIMED_RESPONSE
# Prints TLS handshake ms (time_appconnect - time_connect).
extract_tls_ms() {
	printf '%s' "$1" | grep '__CLIENT_TIMING__' | awk -F: '{print $3}'
}

# extract_transfer_ms TIMED_RESPONSE
# Prints response body transfer ms (time_total - time_starttransfer).
extract_transfer_ms() {
	printf '%s' "$1" | grep '__CLIENT_TIMING__' | awk -F: '{print $5}'
}

# extract_status RESPONSE
# Prints the HTTP status code appended by rtc_post (__HTTP_STATUS__:NNN).
# Returns empty string if not present (e.g. network error / curl failure).
extract_status() {
	printf '%s' "$1" | grep '__HTTP_STATUS__' | grep -o '[0-9]*$'
}

# count_awareness RESPONSE_JSON
# Counts how many client awareness entries are in the response.
# The server returns awareness as {"<client_id>": <state>} -- each state has a
# "name" field from the client's awareness payload, so we count those.
count_awareness() {
	printf '%s' "$1" | grep -o '"name"' | wc -l | tr -d ' ' || true
}

# check_rtc_response RESPONSE_JSON CONTEXT
# Prints a diagnostic and returns 1 if the response is not a valid RTC reply.
check_rtc_response() {
	local resp="$1"
	local ctx="${2:-}"
	if printf '%s' "${resp}" | grep -q '"end_cursor"'; then
		return 0
	fi
	printf 'ERROR%s: RTC endpoint did not return a valid response.\n' \
		"${ctx:+ (${ctx})}"
	printf 'Raw response: %s\n' "${resp}" | head -3
	printf '\nPossible causes:\n'
	printf '  1. Gutenberg RTC feature not enabled (check: wp option get wp_collaboration_enabled)\n'
	printf '  2. The /wp-sync/v1/updates endpoint does not exist on this install\n'
	printf '  3. Authentication failed (check WP_USER and WP_PASS in .env)\n'
	printf '     If you copied .env from another host, run: bash rtc-test.sh refresh-auth\n'
	printf '  4. POST_ID=%s may not exist or user lacks edit permission\n' "${POST_ID}"
	return 1
}

# build_room_json CLIENT_ID AWARENESS_JSON CURSOR UPDATES_JSON
build_room_json() {
	local cid="$1"
	local awareness="$2"
	local cursor="$3"
	local updates="$4"
	printf '{"room":"%s","client_id":%s,"awareness":%s,"after":%s,"updates":[%s]}' \
		"${ROOM}" "${cid}" "${awareness}" "${cursor}" "${updates}"
}

# build_rooms_json ROOM_JSON [ROOM_JSON ...]
build_rooms_json() {
	local rooms=""
	for r in "$@"; do
		[ -n "${rooms}" ] && rooms="${rooms},"
		rooms="${rooms}${r}"
	done
	printf '{"rooms":[%s]}' "${rooms}"
}

# build_update_json TYPE DATA
build_update_json() {
	printf '{"type":"%s","data":"%s"}' "$1" "$2"
}

# print_header LABEL
print_header() {
	printf '\n=== %s ===\n' "$1"
}

# -------------------------------------------------------------------------
# WordPress version enforcement
# -------------------------------------------------------------------------

# ensure_wp_version -- verify the installed WordPress version matches
# REQUIRED_WP_VERSION; download and install it via WP-CLI if not.
# When REQUIRED_WP_VERSION is "nightly", any alpha/beta/RC build is accepted
# and a fresh nightly is only downloaded if nothing is installed yet.
# Pass all WP-CLI flags as arguments (e.g. --path=... --allow-root --url=...).
ensure_wp_version() {
	local current
	current="$(wp "$@" core version 2>/dev/null)" \
		|| { printf 'ERROR: Could not read WordPress version via WP-CLI.\n'; return 1; }

	if [ "${REQUIRED_WP_VERSION}" = "nightly" ]; then
		# Any pre-release build satisfies the nightly requirement.  Re-download
		# only if the site reports no version at all.
		if [ -n "${current}" ]; then
			printf 'WordPress:      %s (nightly or later accepted)\n' "${current}"
			return 0
		fi
		printf 'WordPress:      not installed. Downloading nightly...\n'
		wp "$@" core download --version=nightly --skip-content \
			|| { printf 'ERROR: WP nightly download failed.\n'; return 1; }
		wp "$@" core update-db \
			|| printf 'WARNING: Database update step failed or was not needed.\n'
		return 0
	fi

	if [ "${current}" = "${REQUIRED_WP_VERSION}" ]; then
		printf 'WordPress:      %s (matches required version)\n' "${current}"
		return 0
	fi

	printf 'WordPress:      %s installed, %s required. Updating...\n' \
		"${current}" "${REQUIRED_WP_VERSION}"

	wp "$@" core update --version="${REQUIRED_WP_VERSION}" --force \
		|| { printf 'ERROR: WP core update to %s failed.\n' "${REQUIRED_WP_VERSION}"; return 1; }

	wp "$@" core update-db \
		|| printf 'WARNING: Database update step failed or was not needed.\n'

	local updated
	updated="$(wp "$@" core version 2>/dev/null)"
	if [ "${updated}" = "${REQUIRED_WP_VERSION}" ]; then
		printf 'WordPress:      updated to %s\n' "${updated}"
	else
		printf 'ERROR: Version after update is %s, expected %s.\n' \
			"${updated}" "${REQUIRED_WP_VERSION}"
		return 1
	fi
}

cmd_ensure_wp_version() {
	print_header "ensure-wp-version"
	command -v wp >/dev/null 2>&1 || die "WP-CLI is required for ensure-wp-version."
	[ -n "${WP_PATH:-}" ] || die "WP_PATH is not set. Add it to your .env file."

	local WP_FLAGS=()
	[ "$(id -u)" = "0" ] && WP_FLAGS+=( "--allow-root" )
	WP_FLAGS+=( "--path=${WP_PATH}" )
	[ -n "${WP_URL:-}" ] && WP_FLAGS+=( "--url=${WP_URL}" )

	ensure_wp_version "${WP_FLAGS[@]}"
}

# -------------------------------------------------------------------------
# Approach helpers
# -------------------------------------------------------------------------

# approach_patch_file APPROACH -- prints the absolute patch file path, or empty
# string if the approach is the RC2 baseline (no patch required).
approach_patch_file() {
	case "$1" in
		custom-table)         printf '%s' "${SCRIPT_DIR}/patches/02-custom-table.patch" ;;
		post-meta-transients) printf '%s' "${SCRIPT_DIR}/patches/03-post-meta-transients.patch" ;;
		custom-table-with-transients)  printf '%s' "${SCRIPT_DIR}/patches/04-custom-table-with-transients.patch" ;;
		*)                    printf '' ;;  # post-meta (RC2 baseline) or empty
	esac
}

# approach_has_schema_change APPROACH -- returns 0 if the approach adds the
# wp_collaboration table (requires wp core update-db and table teardown).
approach_has_schema_change() {
	case "$1" in
		custom-table|custom-table-with-transients) return 0 ;;
		*) return 1 ;;
	esac
}

# _build_wp_flags -- populates a local array named WP_FLAGS from the current
# environment. Call as: local WP_FLAGS=(); _build_wp_flags
_build_wp_flags() {
	[ "$(id -u)" = "0" ] && WP_FLAGS+=( "--allow-root" )
	WP_FLAGS+=( "--path=${WP_PATH}" )
	[ -n "${WP_URL:-}" ] && WP_FLAGS+=( "--url=${WP_URL}" )
}

# _clear_rtc_data WP_FLAGS... -- deletes all RTC collaboration data so the next
# approach starts from a clean state. Handles all three storage types safely:
# post meta rows, the collaboration table (if present), and awareness transients.
_clear_rtc_data() {
	printf 'Clearing RTC collaboration data...\n'
	wp "$@" eval '
		global $wpdb;

		// Remove post meta rows written by the post-meta storage implementation.
		$deleted = (int) $wpdb->query(
			"DELETE FROM {$wpdb->postmeta}
			 WHERE meta_key IN (\"wp_sync_update\", \"wp_sync_awareness_state\")"
		);
		echo "  Post meta RTC rows deleted: {$deleted}\n";

		// Truncate the collaboration table if it exists (custom-table approaches).
		$collab = $wpdb->prefix . "collaboration";
		$exists = $wpdb->get_var( $wpdb->prepare( "SHOW TABLES LIKE %s", $collab ) );
		if ( $exists ) {
			$wpdb->query( "TRUNCATE TABLE `{$collab}`" );
			echo "  Collaboration table truncated.\n";
		}

		// Remove awareness transients (post-meta-transients approach).
		$deleted = (int) $wpdb->query(
			"DELETE FROM {$wpdb->options}
			 WHERE option_name LIKE \"_transient_wp_sync_awareness%\"
			    OR option_name LIKE \"_transient_timeout_wp_sync_awareness%\""
		);
		if ( $deleted > 0 ) {
			echo "  Awareness transients deleted: {$deleted}\n";
		}
	' 2>/dev/null || printf '  WARNING: Could not clear RTC data via WP-CLI.\n'
}


cmd_apply_approach() {
	local approach="${1:-}"
	[ -n "${approach}" ] || die "Usage: bash rtc-test.sh apply-approach <approach>
  Approaches: post-meta  custom-table  post-meta-transients  custom-table-with-transients"

	case "${approach}" in
		post-meta|custom-table|post-meta-transients|custom-table-with-transients) ;;
		*) die "Unknown approach '${approach}'. Valid: post-meta  custom-table  post-meta-transients  custom-table-with-transients" ;;
	esac

	print_header "apply-approach (${approach})"
	command -v wp >/dev/null 2>&1 || die "WP-CLI is required for apply-approach."
	[ -n "${WP_PATH:-}" ] || die "WP_PATH is not set. Add it to your .env file."

	local WP_FLAGS=()
	_build_wp_flags

	# Step 1: Reset to a clean nightly build so every approach starts from identical files.
	printf 'Downloading WordPress nightly...\n'
	wp "${WP_FLAGS[@]}" core download --force --version=nightly --skip-content \
		|| die "Failed to download WordPress nightly."

	# Step 2: Re-copy the MU-plugin (nightly download does not touch wp-content, but
	# re-copying ensures the plugin version matches this repo).
	local mu_dir="${WP_PATH}/wp-content/mu-plugins"
	mkdir -p "${mu_dir}"
	cp "${SCRIPT_DIR}/rtc-test.php" "${mu_dir}/rtc-test.php" \
		&& printf 'MU-plugin:      re-copied\n' \
		|| printf 'WARNING: Could not re-copy MU-plugin.\n'

	# Step 3: Baseline DB upgrade (nightly may carry a newer schema than what is in the DB).
	wp "${WP_FLAGS[@]}" core update-db >/dev/null 2>&1 || true

	# Step 4: Apply the approach's patch (post-meta is the nightly baseline, no patch needed).
	local new_patch
	new_patch="$(approach_patch_file "${approach}")"
	if [ -n "${new_patch}" ]; then
		[ -f "${new_patch}" ] || die "Patch file not found: ${new_patch}"

		# Remove any files that this patch would create fresh.  wp core download
		# does not delete files that are absent from the nightly package, so files
		# added by a previous approach's patch would still be on disk and cause
		# patch to detect an "already exists" conflict.
		# New-file hunks have "--- /dev/null" as their source; the destination line
		# is "+++ b/src/<path>" which, with -p2, maps to <path> under WP_PATH.
		local _del_count=0
		while IFS= read -r _rel; do
			local _target="${WP_PATH}/${_rel}"
			if [ -f "${_target}" ]; then
				rm -f "${_target}"
				_del_count=$(( _del_count + 1 ))
			fi
		done < <(grep -A1 '^--- /dev/null' "${new_patch}" \
		         | grep '^\+\+\+ ' \
		         | sed 's|^\+\+\+ b/src/||')
		[ "${_del_count}" -gt 0 ] && \
			printf 'Removed %d file(s) added by a previous patch.\n' "${_del_count}"

		printf 'Applying patch for %s...\n' "${approach}"
		local _fwd_dry
		if ! _fwd_dry=$(patch --dry-run --batch -p2 --ignore-whitespace -d "${WP_PATH}" < "${new_patch}" 2>&1); then
			printf '%s\n' "${_fwd_dry}"
			die "Patch dry-run failed. The patch context does not match the nightly files.
  Check which file/hunk is listed above."
		fi
		patch --batch -p2 --ignore-whitespace -d "${WP_PATH}" < "${new_patch}" \
			|| die "Patch failed. WordPress files may be in an inconsistent state."
		printf 'Patch applied.\n'
	else
		printf 'Approach %s is the nightly baseline — no patch needed.\n' "${approach}"
	fi

	# Step 5: Run DB upgrade again if the approach introduces a schema change (adds the
	# wp_collaboration table).  wp_is_collaboration_enabled() requires db_version >= 61841.
	if approach_has_schema_change "${approach}"; then
		printf 'Running database upgrade (adds collaboration table and/or presence table)...\n'
		wp "${WP_FLAGS[@]}" core update-db || die "Database upgrade failed."
		local db_ver
		db_ver="$(wp "${WP_FLAGS[@]}" option get db_version 2>/dev/null)"
		if [ "${db_ver:-0}" -ge 61841 ] 2>/dev/null; then
			printf 'Database:       version %s (collaboration table ready)\n' "${db_ver}"
		else
			printf 'WARNING: db_version is %s, expected >= 61841. RTC may not activate.\n' "${db_ver}"
		fi
	fi

	# Step 6: Clear all RTC data so this run starts from a clean state.
	_clear_rtc_data "${WP_FLAGS[@]}"

	# Step 7: Flush the object cache.
	wp "${WP_FLAGS[@]}" cache flush 2>/dev/null \
		&& printf 'Object cache:   flushed\n' \
		|| printf 'Object cache:   no external cache to flush\n'

	# Step 8: Ensure RTC is enabled.
	wp "${WP_FLAGS[@]}" option update wp_collaboration_enabled 1 >/dev/null 2>&1 \
		&& printf 'RTC:            enabled\n' \
		|| printf 'WARNING: Could not enable RTC. Verify in Settings > Writing.\n'

	printf '\nApproach "%s" is ready. Run tests with APPROACH="%s".\n' \
		"${approach}" "${approach}"
}

cmd_reset_approach() {
	print_header "reset-approach"
	command -v wp >/dev/null 2>&1 || die "WP-CLI is required for reset-approach."
	[ -n "${WP_PATH:-}" ] || die "WP_PATH is not set. Add it to your .env file."

	local WP_FLAGS=()
	_build_wp_flags

	printf 'Downloading WordPress nightly...\n'
	wp "${WP_FLAGS[@]}" core download --force --version=nightly --skip-content \
		|| die "Failed to download WordPress nightly."

	# Remove any files added by approach patches — wp core download leaves them behind.
	local _patch_file _del_count=0 _rel _target
	for _patch_file in "${SCRIPT_DIR}/patches/"*.patch; do
		[ -f "${_patch_file}" ] || continue
		while IFS= read -r _rel; do
			_target="${WP_PATH}/${_rel}"
			if [ -f "${_target}" ]; then
				rm -f "${_target}"
				_del_count=$(( _del_count + 1 ))
			fi
		done < <(grep -A1 '^--- /dev/null' "${_patch_file}" \
		         | grep '^\+\+\+ ' \
		         | sed 's|^\+\+\+ b/src/||')
	done
	[ "${_del_count}" -gt 0 ] && \
		printf 'Removed %d file(s) added by approach patches.\n' "${_del_count}"

	local mu_dir="${WP_PATH}/wp-content/mu-plugins"
	mkdir -p "${mu_dir}"
	cp "${SCRIPT_DIR}/rtc-test.php" "${mu_dir}/rtc-test.php" \
		&& printf 'MU-plugin:      re-copied\n' \
		|| printf 'WARNING: Could not re-copy MU-plugin.\n'

	wp "${WP_FLAGS[@]}" core update-db >/dev/null 2>&1 || true
	wp "${WP_FLAGS[@]}" cache flush 2>/dev/null || true
	wp "${WP_FLAGS[@]}" option update wp_collaboration_enabled 1 >/dev/null 2>&1 || true

	printf '\nReset to clean nightly.\n'
}

# -------------------------------------------------------------------------
# Commands
# -------------------------------------------------------------------------

cmd_setup() {
	print_header "setup"
	if command -v wp >/dev/null 2>&1; then
		setup_wpcli
	else
		setup_manual
	fi
}

setup_wpcli() {
	printf 'WP-CLI found. Auto-configuring...\n\n'

	# WP_PATH is required for setup; no auto-detection.
	if [ -z "${WP_PATH:-}" ]; then
		printf 'ERROR: WP_PATH is not set.\n'
		printf 'Add it to your .env file (copy .env.example if you have not already):\n'
		printf '  WP_PATH="/var/www/html"\n'
		printf '\nThen re-run: bash rtc-test.sh setup\n\n'
		setup_manual
		return 1
	fi

	local WP_FLAGS=()
	[ "$(id -u)" = "0" ] && WP_FLAGS+=( "--allow-root" )
	WP_FLAGS+=( "--path=${WP_PATH}" )

	if ! wp "${WP_FLAGS[@]}" core version >/dev/null 2>&1; then
		printf 'WP-CLI cannot reach WordPress at: %s\n' "${WP_PATH}"
		printf 'Verify WP_PATH points to the directory containing wp-config.php.\n\n'
		setup_manual
		return 1
	fi
	printf 'WordPress root: %s\n' "${WP_PATH}"

	# Pull the authoritative site URL from the database, then add it to flags
	# so multisite / subdomain installs resolve correctly.
	local site_url
	site_url="$(wp "${WP_FLAGS[@]}" option get siteurl 2>/dev/null)" || site_url="${WP_URL}"
	WP_FLAGS+=( "--url=${site_url}" )

	# Verify the URL is reachable before writing it to config. HTTP 200 or 401
	# both confirm the REST API is present; anything else (including curl error 7
	# for "connection refused") means test requests will fail.
	local http_code
	http_code="$(curl --silent --max-time 5 -o /dev/null -w '%{http_code}' \
		"${site_url}/wp-json/" 2>/dev/null)" || http_code="000"
	case "${http_code}" in
		200|401)
			printf 'Site URL:       %s  (reachable, HTTP %s)\n' "${site_url}" "${http_code}" ;;
		*)
			printf 'Site URL:       %s\n' "${site_url}"
			printf 'WARNING: %s/wp-json/ returned HTTP %s.\n' "${site_url}" "${http_code}"
			printf 'Test requests will likely fail. Check that this URL is reachable\n'
			printf 'from the host running this script.\n' ;;
	esac

	# Ensure the required WordPress version is installed before proceeding.
	ensure_wp_version "${WP_FLAGS[@]}" || die "WordPress version requirement not met. Aborting setup."

	# Copy the MU-plugin now, before login/nonce steps that depend on it being active.
	local wp_content_dir mu_plugins_dir
	wp_content_dir="$(wp "${WP_FLAGS[@]}" eval 'echo WP_CONTENT_DIR;' 2>/dev/null)"
	mu_plugins_dir="${wp_content_dir}/mu-plugins"
	if mkdir -p "${mu_plugins_dir}" 2>/dev/null \
			&& cp "${SCRIPT_DIR}/rtc-test.php" "${mu_plugins_dir}/rtc-test.php" 2>/dev/null; then
		printf 'MU-plugin:      copied to %s\n' "${mu_plugins_dir}"
	else
		printf 'WARNING: Could not copy rtc-test.php to %s\n' "${mu_plugins_dir}"
		printf '  Copy it manually:\n'
		printf '    cp "%s/rtc-test.php" "%s/"\n' "${SCRIPT_DIR}" "${mu_plugins_dir}"
	fi

	# Always use the dedicated rtctest user so setup controls the password.
	# We generate the password here and either create or reset the account.
	local rtctest_wp_pass
	rtctest_wp_pass="$(openssl rand -hex 16 2>/dev/null)" \
		|| rtctest_wp_pass="RtcTest$(date +%s)"

	if wp "${WP_FLAGS[@]}" user get rtctest --fields=ID --format=csv >/dev/null 2>&1; then
		# rtctest already exists -- reset password so we have a known credential.
		wp "${WP_FLAGS[@]}" user update rtctest --user_pass="${rtctest_wp_pass}" \
			>/dev/null 2>&1 || die "Failed to reset rtctest password."
		printf 'User:           rtctest (password reset)\n'
	else
		printf 'Creating dedicated "rtctest" user (editor role)...\n'
		wp "${WP_FLAGS[@]}" user create rtctest rtctest@example.com \
			--role=editor \
			--user_pass="${rtctest_wp_pass}" \
			--porcelain >/dev/null \
			|| die "Failed to create rtctest user."
		printf 'User:           rtctest (created)\n'
	fi
	WP_USER="rtctest"

	# Fetch numeric ID -- wp post create --post_author requires an ID, not a login.
	local user_id
	user_id="$(wp "${WP_FLAGS[@]}" user get rtctest --field=ID 2>/dev/null)"

	# Log in via wp-login.php to obtain a session cookie.
	local jar="${SCRIPT_DIR}/rtc-test-cookies.txt"
	rm -f "${jar}"
	printf 'Logging in...\n'
	do_login "rtctest" "${rtctest_wp_pass}" "${site_url}" "${jar}" \
		|| die "Cookie login failed. Check site URL and that rtctest@example.com is reachable."
	printf 'Cookies:        obtained (%s)\n' "${jar}"

	# Get the wp_rest nonce via the rtctest_nonce AJAX handler in the monitor plugin.
	printf 'Fetching nonce...\n'
	local nonce
	nonce=$(do_get_nonce "${site_url}" "${jar}")
	[ -n "${nonce}" ] || die "Empty nonce. Is rtc-test.php deployed and active?"
	printf 'Nonce:          obtained (%s...)\n' "${nonce:0:8}"

	# Create a dedicated test post so test traffic is isolated from real content.
	printf 'Creating test post...\n'
	local post_id
	post_id="$(wp "${WP_FLAGS[@]}" post create \
		--post_title="RTC Test Post [rtc-test.sh]" \
		--post_status=publish \
		--post_type=post \
		--post_author="${user_id}" \
		--porcelain 2>/dev/null)" \
		|| die "Failed to create test post."
	printf 'Test post ID:   %s\n' "${post_id}"

	# Enable Real Time Collaboration.
	if wp "${WP_FLAGS[@]}" option update wp_collaboration_enabled 1 >/dev/null 2>&1; then
		printf 'RTC:            enabled\n'
	else
		printf 'RTC:            could not update option -- verify in Settings > Writing\n'
	fi

	# Check if SAVEQUERIES is already defined and enabled in wp-config.php.
	savequeries_value=$(wp "${WP_FLAGS[@]}" config get SAVEQUERIES 2>/dev/null)
	if [ "$savequeries_value" = "true" ] || [ "$savequeries_value" = "1" ]; then
		printf 'SAVEQUERIES:    already enabled in wp-config.php\n'
	# Enable SAVEQUERIES so the plugin can record per-request DB time.
	elif wp "${WP_FLAGS[@]}" config set SAVEQUERIES true --raw >/dev/null 2>&1; then
		printf 'SAVEQUERIES:    enabled in wp-config.php\n'
	else
		die "Could not set SAVEQUERIES in wp-config.php. Ensure the file is writable and re-run setup."
	fi

	# Gutenberg must not be active during tests — it ships its own RTC implementation
	# that would interfere with the approaches under test.
	if wp "${WP_FLAGS[@]}" plugin is-installed gutenberg >/dev/null 2>&1; then
		printf 'Gutenberg:      installed\n'
		if wp "${WP_FLAGS[@]}" plugin is-active gutenberg >/dev/null 2>&1; then
			printf 'Gutenberg:      active -- deactivating...\n'
			if wp "${WP_FLAGS[@]}" plugin deactivate gutenberg >/dev/null 2>&1; then
				printf 'Gutenberg:      deactivated\n'
			else
				die "Could not deactivate Gutenberg. Deactivate it manually and re-run setup."
			fi
		else
			printf 'Gutenberg:      not active\n'
		fi
	else
		printf 'Gutenberg:      not installed\n'
	fi

	# Write generated values to .env (or .env.example if .env does not exist yet).
	# Strip any previous generated section first (from the marker line to EOF),
	# then append the fresh block.
	local env_file
	env_file="$(resolve_env_file)"
	local tmp
	tmp="$(mktemp)"
	awk '/Generated by setup/{found=1} !found{print}' "${env_file}" > "${tmp}" \
		&& mv "${tmp}" "${env_file}"

	{
		printf '\n# ── Generated by setup ─────────────────────────────────────────────────────\n'
		printf '# The values below are written automatically by "bash rtc-test.sh setup".\n'
		printf '# Do not edit them manually — re-run setup or refresh-auth to regenerate.\n'
		printf '\n'
		printf 'WP_URL="%s"\n'   "${site_url}"
		printf 'WP_USER="rtctest"\n'
		printf 'WP_PASS="%s"\n'  "${rtctest_wp_pass}"
		printf 'WP_NONCE="%s"\n' "${nonce}"
		printf 'POST_ID="%s"\n'  "${post_id}"
		printf '_RTC_POST_ID_AUTO=1\n'
	} >> "${env_file}"

	printf '\nGenerated values written to %s\n' "${env_file}"
	printf '\nNext steps:\n'
	printf '  bash rtc-test.sh baseline\n'
	printf '  bash rtc-test.sh single-idle\n'
	printf '  bash rtc-test.sh report\n'
	printf '  bash rtc-test.sh teardown   # when done\n'
}

setup_manual() {
	printf 'WP-CLI not available. Manual setup steps:\n\n'
	printf '1. Copy rtc-test.php to the site'"'"'s mu-plugins directory:\n'
	printf '   cp rtc-test.php /path/to/wp-content/mu-plugins/\n\n'
	printf '2. Enable RTC: WP Admin > Settings > Writing > "Enable early access to\n'
	printf '   real-time collaboration"\n\n'
	printf '3. Note a post ID for an existing editor-role user you want to test with.\n\n'
	printf '4. Copy .env.example to .env and fill in the required values:\n\n'
	printf '     cp .env.example .env\n\n'
	printf '   Required values:\n'
	printf '     WP_URL="%s"\n'      "${WP_URL}"
	printf '     WP_USER="<login>"\n'
	printf '     WP_PASS="<password>"\n'
	printf '     WP_PATH="<absolute path to WordPress root>"\n'
	printf '     POST_ID=<post_id>\n\n'
	printf '5. Then run:\n'
	printf '     bash rtc-test.sh refresh-auth   # logs in and writes cookie jar + nonce\n\n'
	printf 'After that, all test commands are available.\n'
}

cmd_teardown() {
	print_header "teardown"

	# Re-source config so teardown works even if vars are not in the environment.
	local config_file
	config_file="$(resolve_env_file)"
	# shellcheck source=/dev/null
	[ -f "${config_file}" ] && . "${config_file}"

	# Remove cookie jar if present.
	local jar="${WP_COOKIE_JAR:-${SCRIPT_DIR}/rtc-test-cookies.txt}"
	if [ -f "${jar}" ]; then
		rm "${jar}"
		printf 'Removed %s\n' "${jar}"
	fi

	if command -v wp >/dev/null 2>&1; then
		local WP_FLAGS=()
		[ "$(id -u)" = "0" ] && WP_FLAGS+=( "--allow-root" )
		[ -n "${WP_URL:-}" ]  && WP_FLAGS+=( "--url=${WP_URL}" )
		[ -n "${WP_PATH:-}" ] && WP_FLAGS+=( "--path=${WP_PATH}" )

		if [ "${_RTC_POST_ID_AUTO:-0}" = "1" ] && [ -n "${POST_ID:-}" ]; then
			printf 'Deleting test post %s...\n' "${POST_ID}"
			wp "${WP_FLAGS[@]}" post delete "${POST_ID}" --force \
				>/dev/null 2>&1 && printf '  Done.\n' || printf '  Already removed.\n'
		fi
	fi

	# Strip the generated section from the env file, leaving user config intact.
	if [ -f "${config_file}" ]; then
		local tmp
		tmp="$(mktemp)"
		awk '/Generated by setup/{found=1} !found{print}' "${config_file}" > "${tmp}" \
			&& mv "${tmp}" "${config_file}"
		printf 'Stripped generated values from %s\n' "${config_file}"
	fi

	printf '\nTeardown complete.\n'
}

cmd_refresh_auth() {
	print_header "refresh-auth"
	local config_file
	config_file="$(resolve_env_file)"
	[ -f "${config_file}" ] || die "No .env or .env.example found. Run: bash rtc-test.sh setup"
	# shellcheck source=/dev/null
	. "${config_file}"
	[ -n "${WP_PASS:-}" ]  || die "WP_PASS not set. Run setup first, or add it to ${config_file}."
	[ -n "${WP_USER:-}" ]  || die "WP_USER not set. Run setup first, or add it to ${config_file}."
	[ -n "${WP_URL:-}" ]   || die "WP_URL not set. Run setup first, or add it to ${config_file}."

	local jar="${WP_COOKIE_JAR:-${SCRIPT_DIR}/rtc-test-cookies.txt}"
	rm -f "${jar}"
	printf 'Logging in as %s...\n' "${WP_USER}"
	do_login "${WP_USER}" "${WP_PASS}" "${WP_URL}" "${jar}" \
		|| die "Cookie login failed. Check WP_URL and WP_PASS in ${config_file}."
	printf 'Cookies:    obtained (%s)\n' "${jar}"

	local nonce
	nonce=$(do_get_nonce "${WP_URL}" "${jar}")
	[ -n "${nonce}" ] || die "Empty nonce. Is rtc-test.php deployed and active?"
	printf 'Nonce:      obtained (%s...)\n' "${nonce:0:8}"

	# Update WP_NONCE in the env file in-place.
	# Use a temp file instead of sed -i to avoid BSD/GNU portability issues.
	local tmp
	tmp=$(mktemp)
	sed "s|^WP_NONCE=.*|WP_NONCE=\"${nonce}\"|" "${config_file}" > "${tmp}" \
		&& mv "${tmp}" "${config_file}"
	printf 'Updated WP_NONCE in %s\n' "${config_file}"
	printf '\nAuth refreshed. Restart any long-running test scripts to pick up the new nonce.\n'
}

cmd_baseline() {
	print_header "baseline (${POLLS} polls)"
	# No auth: wp/v2/types is public. Keeping auth out of baseline gives a
	# cleaner lower bound for WP REST overhead without credential round-trips.
	# We capture full timing breakdown so server_ms can be used as the
	# cross-environment baseline instead of total_ms.

	local total_ms=0
	local total_srv=0
	local i=1
	while [ "${i}" -le "${POLLS}" ]; do
		local raw
		raw=$(curl --silent --show-error \
			-o /dev/null \
			-w '%{time_namelookup}:%{time_connect}:%{time_appconnect}:%{time_pretransfer}:%{time_starttransfer}:%{time_total}' \
			"${WP_URL}/wp-json/wp/v2/types")
		local ms connect_ms tls_ms server_ms
		ms=$(printf '%s' "${raw}" | awk -F: '{printf "%.0f", $6*1000}')
		connect_ms=$(printf '%s' "${raw}" | awk -F: '{printf "%.0f", ($2-$1)*1000}')
		tls_ms=$(printf '%s' "${raw}" | awk -F: '{printf "%.0f", ($3-$2)*1000}')
		server_ms=$(printf '%s' "${raw}" | awk -F: '{printf "%.0f", ($5-$4)*1000}')

		if [ "${i}" -eq 1 ]; then
			if [ -n "${connect_ms}" ] && [ "${connect_ms}" -lt 2 ] 2>/dev/null; then
				printf 'Network path: loopback (connect=%sms)\n' "${connect_ms}"
			else
				printf 'Network path: real network (connect=%sms, tls=%sms)\n' "${connect_ms}" "${tls_ms}"
				printf '  server_ms (PHP processing only) is the comparable metric.\n'
			fi
		fi

		printf 'poll %2d: total_ms=%s server_ms=%s\n' "${i}" "${ms}" "${server_ms}"
		total_ms=$((total_ms + ms))
		total_srv=$((total_srv + server_ms))
		i=$((i + 1))
		if [ "${i}" -le "${POLLS}" ]; then sleep "${POLL_DELAY}"; fi
	done
	printf 'mean: total_ms=%s server_ms=%s\n' "$((total_ms / POLLS))" "$((total_srv / POLLS))"

	# Also poll the RTC endpoint so baseline latency is captured in the log table.
	# Always tagged with approach=baseline regardless of $APPROACH, so all runs
	# across all approaches accumulate into a single results['baseline']['baseline']
	# bucket with N*approaches entries.
	require_auth
	printf '\nLogging %d RTC baseline polls (approach=baseline)...\n' "${POLLS}"
	local rtc_baseline_opts=(
		--silent --show-error
		-b "${WP_COOKIE_JAR}"
		-H "X-WP-Nonce: ${WP_NONCE}"
		-H "X-RTC-Test: 1"
		-H "Content-Type: application/json"
		-H "X-RTC-Approach: baseline"
		-H "X-RTC-Scenario: baseline"
	)
	local room body rtc_url
	room=$(build_room_json "${CLIENT_A}" "${AWARENESS_A}" "0" "")
	body=$(build_rooms_json "${room}")
	rtc_url="${RTC_ENDPOINT}?_rtctest=1&_rtcscenario=baseline&_rtcapproach=baseline&_wpnonce=${WP_NONCE}"
	i=1
	while [ "${i}" -le "${POLLS}" ]; do
		curl "${rtc_baseline_opts[@]}" -X POST "${rtc_url}" -d "${body}" -o /dev/null
		printf 'poll %2d logged\n' "${i}"
		i=$((i + 1))
		if [ "${i}" -le "${POLLS}" ]; then sleep "${POLL_DELAY}"; fi
	done
}

cmd_single_idle() {
	print_header "single-idle (${POLLS} polls, client ${CLIENT_A})"
	require_auth

	local cursor=0
	local i=1
	while [ "${i}" -le "${POLLS}" ]; do
		local room
		room=$(build_room_json "${CLIENT_A}" "${AWARENESS_A}" "${cursor}" "")
		local body
		body=$(build_rooms_json "${room}")

		local response
		response=$(rtc_post_timed "single-idle" "${body}")
		local resp_json
		resp_json=$(printf '%s' "${response}" | grep -v '__CLIENT_MS__' | grep -v '__CLIENT_TIMING__' | grep -v '^$' || true)
		local client_ms server_ms connect_ms tls_ms transfer_ms
		client_ms=$(extract_client_ms "${response}")
		server_ms=$(extract_server_ms "${response}")
		connect_ms=$(extract_connect_ms "${response}")
		tls_ms=$(extract_tls_ms "${response}")
		transfer_ms=$(extract_transfer_ms "${response}")

		# On the first poll, show the full timing breakdown and verify the endpoint.
		if [ "${i}" -eq 1 ]; then
			printf 'Timing breakdown (ms): connect=%s tls=%s server=%s transfer=%s total=%s\n' \
				"${connect_ms}" "${tls_ms}" "${server_ms}" "${transfer_ms}" "${client_ms}"
			if [ -n "${tls_ms}" ] && [ "${tls_ms}" -gt 50 ] 2>/dev/null; then
				printf '  NOTE: TLS handshake dominates. server_ms is PHP+DB only and is\n'
				printf '  the correct metric to compare across environments.\n'
			fi
			check_rtc_response "${resp_json}" "single-idle" || return 1

			# Verify the plugin's monitoring hook activated and data was written.
			# X-RTC-Test-Active: hook ran; X-RTC-DB-Insert: row was inserted.
			local _hook_active=0 _db_inserted=0 _db_error=""
			if [ -f /tmp/rtctest_last_headers.txt ]; then
				grep -qi 'x-rtc-test-active' /tmp/rtctest_last_headers.txt && _hook_active=1
				grep -qi 'x-rtc-db-insert: 1' /tmp/rtctest_last_headers.txt && _db_inserted=1
				_db_error=$(grep -i 'x-rtc-db-error:' /tmp/rtctest_last_headers.txt \
					| head -1 | sed 's/.*x-rtc-db-error: *//i' | tr -d '\r' || true)
			fi
			if [ "${_hook_active}" = "1" ] && [ "${_db_inserted}" = "1" ]; then
				printf 'Plugin logging: ACTIVE (hook ran, row inserted)\n'
			elif [ "${_hook_active}" = "1" ]; then
				printf 'Plugin logging: HOOK RAN but DB INSERT FAILED.\n'
				[ -n "${_db_error}" ] && printf '  MySQL error: %s\n' "${_db_error}"
				printf '  Check the PHP error log on the server for details.\n'
			else
				printf 'Plugin logging: NOT ACTIVE -- no X-RTC-Test-Active header in response.\n'
				printf '  rtctest_post_dispatch did not run. Possible causes:\n'
				printf '  1. rtc-test.php in mu-plugins is outdated (re-run setup or apply-approach).\n'
				printf '  2. Proxy is blocking both headers AND query params from reaching PHP.\n'
				printf '  3. MU plugin is not loaded (check wp-content/mu-plugins/rtc-test.php).\n'
			fi
		fi

		local new_cursor
		new_cursor=$(extract_cursor "${resp_json}")
		[ -n "${new_cursor}" ] && cursor="${new_cursor}"

		local awareness
		awareness=$(count_awareness "${resp_json}")
		local total_updates
		total_updates=$(extract_update_count "${resp_json}")

		printf 'poll %2d: cursor=%s awareness=%s total_updates=%s total_ms=%s server_ms=%s tls_ms=%s\n' \
			"${i}" "${cursor}" "${awareness}" "${total_updates}" "${client_ms}" "${server_ms}" "${tls_ms}"

		i=$((i + 1))
		if [ "${i}" -le "${POLLS}" ]; then sleep "${POLL_DELAY}"; fi
	done
}

cmd_two_idle() {
	print_header "two-idle (${POLLS} rounds, clients ${CLIENT_A} and ${CLIENT_B})"
	require_auth

	local cursor_a=0
	local cursor_b=0
	local i=1
	while [ "${i}" -le "${POLLS}" ]; do
		# Client A polls.
		local room_a
		room_a=$(build_room_json "${CLIENT_A}" "${AWARENESS_A}" "${cursor_a}" "")
		local resp_a
		resp_a=$(rtc_post "two-idle" "$(build_rooms_json "${room_a}")")
		local new_cursor_a
		new_cursor_a=$(extract_cursor "${resp_a}")
		[ -n "${new_cursor_a}" ] && cursor_a="${new_cursor_a}"
		local awareness_a
		awareness_a=$(count_awareness "${resp_a}" "${CLIENT_A}")

		# Client B polls.
		local room_b
		room_b=$(build_room_json "${CLIENT_B}" "${AWARENESS_B}" "${cursor_b}" "")
		local resp_b
		resp_b=$(rtc_post "two-idle" "$(build_rooms_json "${room_b}")")
		local new_cursor_b
		new_cursor_b=$(extract_cursor "${resp_b}")
		[ -n "${new_cursor_b}" ] && cursor_b="${new_cursor_b}"
		local awareness_b
		awareness_b=$(count_awareness "${resp_b}" "${CLIENT_B}")

		# awareness_a >= 2 means B is visible to A (A sees itself + B).
		# awareness_b >= 2 means A is visible to B.
		local a_sees_b="no"
		local b_sees_a="no"
		[ "${awareness_a}" -ge 2 ] && a_sees_b="yes"
		[ "${awareness_b}" -ge 2 ] && b_sees_a="yes"

		printf 'round %2d: A(cursor=%s aware=%s sees_B=%s) B(cursor=%s aware=%s sees_A=%s)\n' \
			"${i}" "${cursor_a}" "${awareness_a}" "${a_sees_b}" \
			"${cursor_b}" "${awareness_b}" "${b_sees_a}"

		i=$((i + 1))
		if [ "${i}" -le "${POLLS}" ]; then sleep "${POLL_DELAY}"; fi
	done
}

cmd_two_editing() {
	print_header "two-editing (sync handshake, update_size=${UPDATE_SIZE})"
	require_auth

	# Step 1: Client A announces itself with sync_step1.
	printf 'Step 1: Client A sends sync_step1\n'
	local step1_update
	step1_update=$(build_update_json "sync_step1" "${SYNC_STEP1_DATA}")
	local room_a_s1
	room_a_s1=$(build_room_json "${CLIENT_A}" "${AWARENESS_A}" "0" "${step1_update}")
	local resp_a_s1
	resp_a_s1=$(rtc_post "two-editing" "$(build_rooms_json "${room_a_s1}")")
	local cursor_a
	cursor_a=$(extract_cursor "${resp_a_s1}")
	[ -z "${cursor_a}" ] && cursor_a=0
	printf '  -> cursor_a=%s\n' "${cursor_a}"

	# Step 2: Client B polls, receives sync_step1; responds with sync_step2 + update.
	printf 'Step 2: Client B polls (should receive sync_step1), then sends sync_step2 + update\n'
	local step2_update
	step2_update=$(build_update_json "sync_step2" "${SYNC_STEP2_DATA}")
	local edit_update
	edit_update=$(build_update_json "update" "${UPDATE_DATA}")
	local room_b_s2
	room_b_s2=$(build_room_json "${CLIENT_B}" "${AWARENESS_B}" "0" "${step2_update},${edit_update}")
	local resp_b_s2
	resp_b_s2=$(rtc_post "two-editing" "$(build_rooms_json "${room_b_s2}")")
	local cursor_b
	cursor_b=$(extract_cursor "${resp_b_s2}")
	[ -z "${cursor_b}" ] && cursor_b=0

	# Check B received sync_step1 from A.
	local b_received_step1
	b_received_step1=$(printf '%s' "${resp_b_s2}" | grep -c '"type":"sync_step1"' || true)
	printf '  -> B received sync_step1 from A: %s | cursor_b=%s\n' \
		"$([ "${b_received_step1}" -gt 0 ] && echo yes || echo no)" "${cursor_b}"

	# Step 3: Client A polls to receive sync_step2 and update from B.
	printf 'Step 3: Client A polls (should receive sync_step2 + update from B)\n'
	local room_a_s3
	room_a_s3=$(build_room_json "${CLIENT_A}" "${AWARENESS_A}" "${cursor_a}" "")
	local resp_a_s3
	resp_a_s3=$(rtc_post "two-editing" "$(build_rooms_json "${room_a_s3}")")
	local new_cursor_a
	new_cursor_a=$(extract_cursor "${resp_a_s3}")
	[ -n "${new_cursor_a}" ] && cursor_a="${new_cursor_a}"

	local a_received_step2
	a_received_step2=$(printf '%s' "${resp_a_s3}" | grep -c '"type":"sync_step2"' || true)
	local a_received_update
	a_received_update=$(printf '%s' "${resp_a_s3}" | grep -c '"type":"update"' || true)
	local total_updates
	total_updates=$(extract_update_count "${resp_a_s3}")

	printf '  -> A received sync_step2: %s | update: %s | cursor_a=%s | total_updates=%s\n' \
		"$([ "${a_received_step2}" -gt 0 ] && echo yes || echo no)" \
		"$([ "${a_received_update}" -gt 0 ] && echo yes || echo no)" \
		"${cursor_a}" "${total_updates}"

	printf '\nHandshake complete.\n'
}

cmd_one_idle_one_editing() {
	print_header "one-idle-one-editing (${POLLS} rounds, update_size=${UPDATE_SIZE})"
	require_auth
	printf 'Client A=%s (editor), Client B=%s (idle viewer)\n' "${CLIENT_A}" "${CLIENT_B}"

	local cursor_a=0
	local cursor_b=0
	local i=1
	while [ "${i}" -le "${POLLS}" ]; do
		# Client A sends one update per round.
		local edit_update
		edit_update=$(build_update_json "update" "${UPDATE_DATA}")
		local room_a
		room_a=$(build_room_json "${CLIENT_A}" "${AWARENESS_A}" "${cursor_a}" "${edit_update}")
		local resp_a
		resp_a=$(rtc_post_timed "one-idle-one-editing" "$(build_rooms_json "${room_a}")")
		local resp_a_json
		resp_a_json=$(printf '%s' "${resp_a}" | grep -v '__CLIENT_MS__' | grep -v '__CLIENT_TIMING__' | grep -v '^$')
		local ms_a server_ms_a
		ms_a=$(extract_client_ms "${resp_a}")
		server_ms_a=$(extract_server_ms "${resp_a}")
		local new_cursor_a
		new_cursor_a=$(extract_cursor "${resp_a_json}")
		[ -n "${new_cursor_a}" ] && cursor_a="${new_cursor_a}"
		local total_a
		total_a=$(extract_update_count "${resp_a_json}")
		local compact_a
		compact_a=$(extract_should_compact "${resp_a_json}")

		# Client B polls, no updates.
		local room_b
		room_b=$(build_room_json "${CLIENT_B}" "${AWARENESS_B}" "${cursor_b}" "")
		local resp_b
		resp_b=$(rtc_post_timed "one-idle-one-editing" "$(build_rooms_json "${room_b}")")
		local resp_b_json
		resp_b_json=$(printf '%s' "${resp_b}" | grep -v '__CLIENT_MS__' | grep -v '__CLIENT_TIMING__' | grep -v '^$')
		local ms_b server_ms_b
		ms_b=$(extract_client_ms "${resp_b}")
		server_ms_b=$(extract_server_ms "${resp_b}")
		local new_cursor_b
		new_cursor_b=$(extract_cursor "${resp_b_json}")
		[ -n "${new_cursor_b}" ] && cursor_b="${new_cursor_b}"
		# How many updates did the idle client receive this round?
		local updates_delivered
		updates_delivered=$(printf '%s' "${resp_b_json}" | grep -o '"type"' | wc -l | tr -d ' ')

		printf 'round %2d: editor(total_ms=%s srv=%s cursor=%s total=%s compact=%s) idle(total_ms=%s srv=%s cursor=%s delivered=%s)\n' \
			"${i}" "${ms_a}" "${server_ms_a}" "${cursor_a}" "${total_a}" "${compact_a:-false}" \
			"${ms_b}" "${server_ms_b}" "${cursor_b}" "${updates_delivered}"

		i=$((i + 1))
		if [ "${i}" -le "${POLLS}" ]; then sleep "${POLL_DELAY}"; fi
	done
}

cmd_n_idle() {
	print_header "n-idle (${N_CLIENTS} clients, ${POLLS} rounds each)"
	require_auth
	printf 'Client IDs: %s..%s\n' "${CLIENT_A}" "$((CLIENT_A + N_CLIENTS - 1))"

	# Initialize cursors array (bash 3-compatible: use indexed array).
	local cursors=()
	local client_ids=()
	local j=0
	while [ "${j}" -lt "${N_CLIENTS}" ]; do
		cursors+=( 0 )
		client_ids+=( $((CLIENT_A + j)) )
		j=$((j + 1))
	done

	# Awareness payloads per client (deterministic colors from index).
	local round=1
	while [ "${round}" -le "${POLLS}" ]; do
		printf 'round %2d:' "${round}"
		local k=0
		while [ "${k}" -lt "${N_CLIENTS}" ]; do
			local cid="${client_ids[$k]}"
			local cursor="${cursors[$k]}"
			local awareness
			# Generate a distinct name for each client.
			awareness="{\"name\":\"RTC-Test-Client-${cid}\",\"color\":\"#$(printf '%06x' $((cid * 31337 % 16777216)))\"}"
			local room
			room=$(build_room_json "${cid}" "${awareness}" "${cursor}" "")
			local resp
			resp=$(rtc_post "n-idle" "$(build_rooms_json "${room}")")
			local new_cursor
			new_cursor=$(extract_cursor "${resp}")
			[ -n "${new_cursor}" ] && cursors[$k]="${new_cursor}"
			local awareness_count
			awareness_count=$(count_awareness "${resp}" "${cid}")
			printf ' C%s(aware=%s)' "${cid}" "${awareness_count}"
			k=$((k + 1))
		done
		printf '\n'
		round=$((round + 1))
		if [ "${round}" -le "${POLLS}" ]; then sleep "${POLL_DELAY}"; fi
	done
}

cmd_compaction_trigger() {
	print_header "compaction-trigger (threshold=50 updates)"
	require_auth

	local cursor_a=0
	local total=0
	local compact_triggered=false
	local poll=0

	printf 'Sending updates until should_compact=true (compaction threshold is 50)...\n'

	while [ "${compact_triggered}" = "false" ] && [ "${poll}" -lt 80 ]; do
		local edit_update
		edit_update=$(build_update_json "update" "${UPDATE_DATA}")
		local room_a
		room_a=$(build_room_json "${CLIENT_A}" "${AWARENESS_A}" "${cursor_a}" "${edit_update}")
		local resp
		resp=$(rtc_post "compaction-trigger" "$(build_rooms_json "${room_a}")")
		local new_cursor
		new_cursor=$(extract_cursor "${resp}")
		[ -n "${new_cursor}" ] && cursor_a="${new_cursor}"
		total=$(extract_update_count "${resp}")
		local compact
		compact=$(extract_should_compact "${resp}")
		poll=$((poll + 1))

		printf '  update %2d: total_updates=%s cursor=%s should_compact=%s\n' \
			"${poll}" "${total}" "${cursor_a}" "${compact:-false}"

		if [ "${compact}" = "true" ]; then
			compact_triggered=true
		fi
	done

	if [ "${compact_triggered}" = "false" ]; then
		printf 'should_compact never fired after %d polls. Check that CLIENT_A=%s is the\n' "${poll}" "${CLIENT_A}"
		printf 'lowest client_id in the room (only the lowest ID is asked to compact).\n'
		return
	fi

	printf '\nshould_compact triggered at total_updates=%s. Sending compaction update...\n' "${total}"

	# Client A sends a compaction update (replaces updates before cursor_a).
	local compact_update
	compact_update=$(build_update_json "compaction" "${UPDATE_DATA}")
	local room_a_compact
	room_a_compact=$(build_room_json "${CLIENT_A}" "${AWARENESS_A}" "${cursor_a}" "${compact_update}")
	local resp_compact
	resp_compact=$(rtc_post "compaction-trigger" "$(build_rooms_json "${room_a_compact}")")
	local cursor_after_compact
	cursor_after_compact=$(extract_cursor "${resp_compact}")
	[ -n "${cursor_after_compact}" ] && cursor_a="${cursor_after_compact}"

	printf 'Compaction sent. cursor_a=%s\n' "${cursor_a}"

	# Client B polls to verify it receives the compaction update.
	printf '\nClient B polls to verify compaction delivery...\n'
	local room_b
	room_b=$(build_room_json "${CLIENT_B}" "${AWARENESS_B}" "0" "")
	local resp_b
	resp_b=$(rtc_post "compaction-trigger" "$(build_rooms_json "${room_b}")")
	local total_after
	total_after=$(extract_update_count "${resp_b}")
	local cursor_b
	cursor_b=$(extract_cursor "${resp_b}")
	local b_got_compact
	b_got_compact=$(printf '%s' "${resp_b}" | grep -c '"type":"compaction"' || true)

	printf 'Client B: received_compaction=%s total_updates_now=%s cursor_b=%s\n' \
		"$([ "${b_got_compact}" -gt 0 ] && echo yes || echo no)" \
		"${total_after}" "${cursor_b}"

	if [ "${total_after}" -lt "${total}" ]; then
		printf '\nCompaction confirmed: total_updates dropped from %s to %s.\n' "${total}" "${total_after}"
	else
		printf '\nNote: total_updates did not drop (%s -> %s).\n' "${total}" "${total_after}"
		printf 'This is expected if other clients added updates between compaction and this poll.\n'
	fi
}

cmd_concurrent() {
	print_header "concurrent (${N_CLIENTS} simultaneous clients, ${POLLS} rounds)"
	require_auth
	printf 'Client IDs: %s..%s\n' "${CLIENT_A}" "$((CLIENT_A + N_CLIENTS - 1))"
	printf 'All clients fire at the same second each round (rendezvous-synced burst).\n\n'

	# Per-client cursors, updated from responses each round.
	local cursors=()
	local k=0
	while [ "${k}" -lt "${N_CLIENTS}" ]; do
		cursors+=( 0 )
		k=$(( k + 1 ))
	done

	local round=1
	while [ "${round}" -le "${POLLS}" ]; do
		# Rendezvous: all workers spin-wait until 2 seconds from now so requests
		# fire within the same second rather than staggered by process spawn time.
		local start_at
		start_at=$(( $(date +%s) + 2 ))
		local tmpdir
		tmpdir="$(mktemp -d /tmp/rtctest.XXXXXX)"

		# Spawn one background worker per client.
		k=0
		while [ "${k}" -lt "${N_CLIENTS}" ]; do
			local cid=$(( CLIENT_A + k ))
			local cursor="${cursors[$k]}"
			local awareness
			awareness="{\"name\":\"RTC-Concurrent-${cid}\",\"color\":\"#$(printf '%06x' $((cid * 31337 % 16777216)))\"}"
			local room body
			room=$(build_room_json "${cid}" "${awareness}" "${cursor}" "")
			body=$(build_rooms_json "${room}")
			local out="${tmpdir}/${k}"
			local sa="${start_at}"

			(
				# Busy-wait until the rendezvous second.
				while [ "$(date +%s)" -lt "${sa}" ]; do :; done
				curl "${BASE_CURL_OPTS[@]}" \
					-H "X-RTC-Scenario: concurrent" \
					-X POST "${RTC_ENDPOINT}" \
					-d "${body}" \
					-w '\n__HTTP_STATUS__:%{http_code}' \
					2>/dev/null
			) > "${out}" &

			k=$(( k + 1 ))
		done

		# Wait for all background workers to finish.
		wait 2>/dev/null || true

		# Collect results and update cursors for next round.
		printf 'round %2d:' "${round}"
		k=0
		while [ "${k}" -lt "${N_CLIENTS}" ]; do
			local out="${tmpdir}/${k}"
			local new_cursor awareness_count status c
			new_cursor="${cursors[$k]}"
			awareness_count=0
			status=""
			c=""
			if [ -f "${out}" ]; then
				local resp
				resp="$(cat "${out}")" || true
				c="$(extract_cursor "${resp}")"
				status="$(extract_status "${resp}")"
				[ -n "${c}" ] && new_cursor="${c}"
				awareness_count="$(count_awareness "${resp}")"
				awareness_count="${awareness_count:-0}"
			fi
			cursors[$k]="${new_cursor}"
			if [ -n "${c}" ]; then
				printf ' C%s(aware=%s cursor=%s)' "$((CLIENT_A + k))" "${awareness_count}" "${new_cursor}"
			else
				printf ' C%s(ERR:%s)' "$((CLIENT_A + k))" "${status:-net}"
			fi
			k=$(( k + 1 ))
		done
		printf '\n'

		rm -rf "${tmpdir}"

		round=$(( round + 1 ))
		if [ "${round}" -le "${POLLS}" ]; then sleep "${POLL_DELAY}"; fi
	done
	printf '\nRun: bash rtc-test.sh report\n'
	printf 'The "conc" column shows max simultaneous workers seen by the plugin.\n'
}

cmd_sustain() {
	print_header "sustain (${N_CLIENTS} clients, ${DURATION}s, poll interval ${POLL_DELAY}s)"
	require_auth
	printf 'Client IDs: %s..%s\n' "${CLIENT_A}" "$(( CLIENT_A + N_CLIENTS - 1 ))"
	printf 'Each client polls independently (no synchronization).\n'
	printf 'POLL_DELAY=0 keeps clients always in-flight (stress); POLL_DELAY=1 is realistic cadence.\n\n'

	local end_at tmpdir
	end_at=$(( $(date +%s) + DURATION ))
	tmpdir=$(mktemp -d /tmp/rtctest.XXXXXX)

	# Start one independent polling loop per client.
	# Uses rtc_post (not rtc_post_timed) -- no shared temp file, safe for parallel use.
	local k=0
	while [ "${k}" -lt "${N_CLIENTS}" ]; do
		local cid=$(( CLIENT_A + k ))
		local out="${tmpdir}/${k}"
		local ea="${end_at}"
		(
			local cursor=0 polls=0 err_429=0 err_5xx=0 err_net=0
			local awareness room body resp new_cursor status
			awareness="{\"name\":\"Sustain-${cid}\",\"color\":\"#$(printf '%06x' $(( cid * 31337 % 16777216 )))\"}"
			while [ "$(date +%s)" -lt "${ea}" ]; do
				room=$(build_room_json "${cid}" "${awareness}" "${cursor}" "")
				body=$(build_rooms_json "${room}")
				resp=$(rtc_post "sustain" "${body}") || true
				new_cursor=$(extract_cursor "${resp}")
				if [ -n "${new_cursor}" ]; then
					cursor="${new_cursor}"
					polls=$(( polls + 1 ))
				else
					status=$(extract_status "${resp}")
					case "${status}" in
						429)            err_429=$(( err_429 + 1 )) ;;
						5[0-9][0-9])    err_5xx=$(( err_5xx + 1 )) ;;
						*)              err_net=$(( err_net + 1 )) ;;
					esac
				fi
				# Sleep between polls only if time remains and delay is non-zero.
				if [ "${POLL_DELAY}" -gt 0 ] && [ "$(date +%s)" -lt "${ea}" ]; then
					sleep "${POLL_DELAY}"
				fi
			done
			printf '%d %d %d %d %d\n' "${cid}" "${polls}" "${err_429}" "${err_5xx}" "${err_net}" > "${out}"
		) &
		k=$(( k + 1 ))
	done

	# Progress ticker while waiting (prints every 5s so the terminal isn't silent).
	(
		local elapsed=0
		while [ "${elapsed}" -lt "${DURATION}" ]; do
			sleep 5
			elapsed=$(( elapsed + 5 ))
			[ "${elapsed}" -lt "${DURATION}" ] && \
				printf '  %ds / %ds elapsed...\n' "${elapsed}" "${DURATION}"
		done
	) &
	local ticker_pid=$!

	wait 2>/dev/null || true
	kill "${ticker_pid}" 2>/dev/null || true
	wait "${ticker_pid}" 2>/dev/null || true

	printf '\nResults:\n'
	local total_polls=0 total_429=0 total_5xx=0 total_net=0
	k=0
	while [ "${k}" -lt "${N_CLIENTS}" ]; do
		local out="${tmpdir}/${k}"
		local r_cid r_polls r_429 r_5xx r_net
		r_cid=$(( CLIENT_A + k ))
		r_polls=0; r_429=0; r_5xx=0; r_net=0
		if [ -f "${out}" ]; then
			read -r r_cid r_polls r_429 r_5xx r_net < "${out}" || true
		fi
		local r_total_err=$(( r_429 + r_5xx + r_net ))
		if [ "${r_total_err}" -gt 0 ]; then
			printf '  client %d: %d polls, %d errors (429=%d 5xx=%d net=%d)\n' \
				"${r_cid}" "${r_polls}" "${r_total_err}" "${r_429}" "${r_5xx}" "${r_net}"
		else
			printf '  client %d: %d polls, 0 errors\n' "${r_cid}" "${r_polls}"
		fi
		total_polls=$(( total_polls + r_polls ))
		total_429=$(( total_429 + r_429 ))
		total_5xx=$(( total_5xx + r_5xx ))
		total_net=$(( total_net + r_net ))
		k=$(( k + 1 ))
	done
	local total_errors=$(( total_429 + total_5xx + total_net ))
	if [ "${total_errors}" -gt 0 ]; then
		printf 'Total: %d polls, %d errors (429=%d 5xx=%d net=%d) in %ds\n' \
			"${total_polls}" "${total_errors}" "${total_429}" "${total_5xx}" "${total_net}" "${DURATION}"
	else
		printf 'Total: %d polls, 0 errors in %ds\n' "${total_polls}" "${DURATION}"
	fi

	rm -rf "${tmpdir}"
	printf '\nRun: bash rtc-test.sh report\n'
	printf 'Key columns: tot_cpu_ms (full request CPU), conc (max simultaneous workers).\n'
}

# print_env -- fetch and display environment snapshot as a table.
# No header; suitable for embedding in other commands.
print_env() {
	local env
	env=$(curl "${BASE_CURL_OPTS[@]}" "${PLUGIN_ENV_URL}" 2>/dev/null) || true
	if [ -z "${env}" ]; then
		printf '  (could not reach rtc-test/v1/env -- is the plugin active?)\n'
		return
	fi
	# The REST API returns compact single-line JSON. Split on commas so each
	# key:value pair lands on its own line, then strip braces and quotes.
	printf '%s' "${env}" | tr ',' '\n' | awk '
	{
		gsub(/[{}"]/, "")
		if (match($0, /php_version:/))           printf "  %-22s %s\n", "PHP:",          substr($0, RSTART+12)
		if (match($0, /wp_version:/))            printf "  %-22s %s\n", "WordPress:",    substr($0, RSTART+11)
		if (match($0, /db_version:/))            printf "  %-22s %s\n", "Database:",     substr($0, RSTART+11)
		if (match($0, /object_cache_type:/))     printf "  %-22s %s\n", "Object cache:", substr($0, RSTART+18)
		if (match($0, /savequeries:/))           printf "  %-22s %s\n", "SAVEQUERIES:",      substr($0, RSTART+12)
		if (match($0, /compaction_threshold:/))  printf "  %-22s %s updates\n", "Compact at:", substr($0, RSTART+21)
		if (match($0, /awareness_timeout_s:/))   printf "  %-22s %s s\n", "Awareness TTL:",  substr($0, RSTART+20)
	}
	'
}

cmd_env() {
	print_header "env"
	require_auth
	print_env
}

# _print_report_text DATA
# Extracts and prints the pre-formatted "text" field from a {"text":"..."} JSON
# response returned by /rtc-test/v1/report or /rtc-test/v1/report-all.
_print_report_text() {
	local data="$1"
	if [ -z "${data}" ]; then
		printf 'No response from server.\n'
		return 1
	fi
	# A WordPress error response has a "code" field rather than "text".
	case "${data}" in
		*'"code"'*)
			printf 'ERROR: %s\n' "${data}"
			printf '\nPossible causes:\n'
			printf '  1. Plugin not active: copy rtc-test.php to wp-content/mu-plugins/\n'
			printf '  2. User lacks edit_posts capability\n'
			return 1 ;;
	esac
	# Extract the "text" value and unescape JSON \n sequences.
	local text
	text=$(printf '%s' "${data}" | awk -F'"text":"' 'NF>1{ s=$2; sub(/".*$/, "", s); gsub(/\\n/, "\n", s); printf "%s", s }')
	if [ -z "${text}" ]; then
		printf 'No log entries found.\n'
		return
	fi
	printf '%s\n' "${text}"
}

cmd_report() {
	print_header "report"
	require_auth
	printf 'Environment:\n'
	print_env
	printf '\nPer-scenario summary:\n'
	local data
	data=$(curl "${BASE_CURL_OPTS[@]}" "${PLUGIN_REPORT_URL}" 2>/dev/null) || true
	_print_report_text "${data}"
}

cmd_report_all() {
	print_header "report-all"
	require_auth
	local data
	data=$(curl "${BASE_CURL_OPTS[@]}" "${PLUGIN_REPORT_ALL_URL}" 2>/dev/null) || true
	_print_report_text "${data}"
}

cmd_submit_results() {
	print_header "submit-results"
	require_auth

	local reporter_url="${REPORTER_URL}"
	local api_key="${REPORTER_API_KEY:-}"
	if [ -z "${api_key}" ]; then
		printf 'REPORTER_API_KEY must be set to submit results.\n'
		printf 'Skipping submission.\n'
		return 0
	fi
	if [[ "${reporter_url}" != https://* ]]; then
		die "REPORTER_URL must use HTTPS to protect credentials. Got: ${reporter_url}"
	fi

	local environment_name="${ENVIRONMENT_NAME:-${WP_URL}}"

	# Aggregation and submission are handled server-side by the plugin endpoint.
	printf 'Submitting results to %s ...\n' "${reporter_url}"
	local response http_code
	response=$(curl "${BASE_CURL_OPTS[@]}" \
		-X POST "${PLUGIN_SUBMIT_URL}" \
		-H "Content-Type: application/json" \
		-w '\n__HTTP_STATUS__:%{http_code}' \
		-d "$(printf '{"reporter_url":"%s","api_key":"%s","environment_name":"%s"}' \
			"${reporter_url}" "${api_key}" "${environment_name}")" \
		2>/dev/null) || { printf 'ERROR: curl request failed.\n'; return 1; }

	http_code=$(printf '%s' "${response}" | grep '__HTTP_STATUS__' | grep -o '[0-9]*$')
	response=$(printf '%s' "${response}" | grep -v '__HTTP_STATUS__')

	case "${http_code}" in
		2*) printf 'Submitted successfully (HTTP %s).\n' "${http_code}" ;;
		*)  printf 'ERROR: Submission failed (HTTP %s):\n  %s\n' "${http_code}" "${response}"
		    return 1 ;;
	esac
}

cmd_clear() {
	print_header "clear"
	require_auth
	local result
	result=$(curl "${BASE_CURL_OPTS[@]}" -X DELETE "${PLUGIN_LOG_URL}") || die "curl failed"
	printf 'Result: %s\n' "${result}"
}

cmd_reset() {
	print_header "reset"
	require_auth
	printf 'Dropping log table on server (will be recreated automatically on next tagged request)...\n'
	local result
	result=$(curl "${BASE_CURL_OPTS[@]}" -X DELETE "${PLUGIN_TABLE_URL}") || die "curl failed"
	printf 'Result: %s\n' "${result}"
}

# -------------------------------------------------------------------------
# Capture commands
# -------------------------------------------------------------------------

# seed -- populate POST_ID with 5 lorem ipsum Gutenberg paragraphs via REST.
# No WP-CLI required; uses PUT /wp/v2/posts/${POST_ID}.
# Double-quoted bash strings preserve \n as literal backslash-n, which is
# exactly what JSON requires for embedded newlines.
cmd_seed() {
	print_header "seed (post ${POST_ID})"
	require_auth

	local content
	content="<!-- wp:paragraph -->\n<p>Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.</p>\n<!-- /wp:paragraph -->\n\n<!-- wp:paragraph -->\n<p>Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.</p>\n<!-- /wp:paragraph -->\n\n<!-- wp:paragraph -->\n<p>Aenean fermentum elit eget tincidunt condimentum. Eros ipsum rutrum orci sagittis tempus lacus enim ac dui. Donec non enim in turpis pulvinar facilisis. Ut felis. Praesent dapibus neque id cursus faucibus.</p>\n<!-- /wp:paragraph -->\n\n<!-- wp:paragraph -->\n<p>Nam dui mi tincidunt quis accumsan porttitor facilisis luctus metus. Phasellus ultrices nulla quis nibh. Quisque a lectus. Donec consectetuer ligula vulputate sem tristique cursus. Nam nulla quam gravida non commodo.</p>\n<!-- /wp:paragraph -->\n\n<!-- wp:paragraph -->\n<p>Nullam eu ante vel est convallis dignissim. Fusce suscipit wisi nec facilisis facilisis est dui fermentum leo quis tempor ligula erat quis odio. Nunc porta vulputate tellus. Nunc rutrum turpis sed pede.</p>\n<!-- /wp:paragraph -->"

	local result
	result=$(curl "${BASE_CURL_OPTS[@]}" \
		-X PUT \
		"${WP_URL}/wp-json/wp/v2/posts/${POST_ID}" \
		-d "{\"content\":\"${content}\"}") || die "curl failed"

	if printf '%s' "${result}" | grep -q '"id"'; then
		printf 'Post %s seeded with 5 lorem ipsum paragraphs.\n' "${POST_ID}"
		printf 'Editor URL: %s/wp-admin/post.php?post=%s&action=edit\n' "${WP_URL}" "${POST_ID}"
	else
		printf 'ERROR: Unexpected response:\n'
		printf '%s\n' "${result}" | head -5
		return 1
	fi
}

# capture-start SESSION_ID -- begin recording /wp-sync/ traffic for POST_ID.
cmd_capture_start() {
	local session_id="${1:-}"
	[ -z "${session_id}" ] && die "Usage: bash rtc-test.sh capture-start <session-id>"

	print_header "capture-start (${session_id})"
	require_auth

	local result
	result=$(curl "${BASE_CURL_OPTS[@]}" \
		-X POST "${CAPTURE_SESSION_URL}/start" \
		-d "{\"session_id\":\"${session_id}\",\"room_filter\":\"postType/post:${POST_ID}\"}") \
		|| die "curl failed"

	printf 'Result: %s\n' "${result}"
	printf '\nOpen two browser windows and edit the post:\n'
	printf '  %s/wp-admin/post.php?post=%s&action=edit\n' "${WP_URL}" "${POST_ID}"
	printf '\nWhen done: bash rtc-test.sh capture-stop\n'
}

# capture-stop -- stop the active session and print frame count.
cmd_capture_stop() {
	print_header "capture-stop"
	require_auth

	local result
	result=$(curl "${BASE_CURL_OPTS[@]}" \
		-X POST "${CAPTURE_SESSION_URL}/stop") || die "curl failed"

	printf 'Result: %s\n' "${result}"

	local frames
	frames=$(printf '%s' "${result}" | grep -o '"frames":[0-9]*' | grep -o '[0-9]*' || true)
	local sid
	sid=$(printf '%s' "${result}" | grep -o '"session_id":"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"' || true)

	if [ -n "${frames}" ]; then
		printf '\nCaptured %s frames for session "%s".\n' "${frames}" "${sid}"
		printf 'Export: bash rtc-test.sh capture-export %s\n' "${sid}"
	fi
}

# capture-list -- print all captured sessions.
cmd_capture_list() {
	print_header "capture-list"
	require_auth

	local result
	result=$(curl "${BASE_CURL_OPTS[@]}" "${CAPTURE_SESSIONS_URL}") || die "curl failed"

	if [ -z "${result}" ] || [ "${result}" = "[]" ]; then
		printf 'No sessions captured.\n'
		return
	fi

	printf '%s' "${result}" | awk '
	function extract_str(s, key,    pat) {
		pat = "\"" key "\":\""
		if (!match(s, pat "[^\"]+\"")) return ""
		return substr(s, RSTART + length(pat), RLENGTH - length(pat) - 1)
	}
	function extract_num(s, key,    pat) {
		pat = "\"" key "\":[0-9]+"
		if (!match(s, pat)) return 0
		return substr(s, RSTART + length(key) + 3, RLENGTH - length(key) - 3) + 0
	}
	{
		n = split($0, entries, /\},\{/)
		printf "%-30s %7s %13s %11s %s\n", "session_id", "frames", "started(UTC)", "duration_ms", "active"
		printf "%-30s %7s %13s %11s %s\n", "------------------------------", "-------", "-------------", "-----------", "------"
		for (i = 1; i <= n; i++) {
			e = entries[i]
			sid      = extract_str(e, "session_id")
			frames   = extract_num(e, "frames")
			first_us = extract_num(e, "first_us")
			dur_ms   = extract_num(e, "duration_ms")
			active   = (match(e, /"active":true/) ? "yes" : "")
			if (first_us > 0) {
				s = int(first_us / 1000000)
				started = sprintf("%02d:%02d:%02d", int(s%86400/3600), int(s%3600/60), s%60)
			} else { started = "-" }
			printf "%-30s %7d %13s %11d %s\n", sid, frames, started, dur_ms, active
		}
	}
	'
}

# capture-export SESSION_ID -- fetch session JSON to stdout (pipe to file).
cmd_capture_export() {
	local session_id="${1:-}"
	[ -z "${session_id}" ] && die "Usage: bash rtc-test.sh capture-export <session-id>"

	require_auth
	curl "${BASE_CURL_OPTS[@]}" "${CAPTURE_SESSION_URL}/${session_id}" || die "curl failed"
}

# capture-drop [SESSION_ID] -- delete a session or the entire table.
# With no argument, prompts before dropping all.
cmd_capture_drop() {
	local session_id="${1:-}"
	require_auth

	if [ -n "${session_id}" ]; then
		print_header "capture-drop (${session_id})"
		local result
		result=$(curl "${BASE_CURL_OPTS[@]}" \
			-X DELETE "${CAPTURE_SESSION_URL}/${session_id}") || die "curl failed"
		printf 'Result: %s\n' "${result}"
	else
		print_header "capture-drop (all)"
		printf 'Drop the entire capture table? [y/N] '
		read -r confirm
		if [ "${confirm}" = "y" ] || [ "${confirm}" = "Y" ]; then
			local result
			result=$(curl "${BASE_CURL_OPTS[@]}" \
				-X DELETE "${CAPTURE_SESSIONS_URL}") || die "curl failed"
			printf 'Result: %s\n' "${result}"
		else
			printf 'Cancelled.\n'
		fi
	fi
}

# -------------------------------------------------------------------------
# Replay command
# -------------------------------------------------------------------------

# capture-sanitize FIXTURE_FILE -- strip site-specific and personal data from a raw
# capture-export fixture, producing a portable file safe to share or bundle.
#
# What is removed:
#   response bodies       -- contain site-specific cursors; unused by replay
#   non-post rooms        -- root/comment, taxonomy/*, postType/wp_block; ignored by replay
#   awareness payloads    -- may contain user display names from the browser session
#   captured after cursor -- site-specific; replay always uses live cursors
#
# What is kept:
#   elapsed_ms            -- inter-frame timing for realistic replay speed
#   client_id             -- distinguishes which tab each frame came from
#   updates               -- the actual Yjs binary delta payloads (the core data)
#
# Room is normalized to postType/post:0 (replay substitutes the live POST_ID anyway).
#
# Output goes to stdout so the original is never modified:
#   bash rtc-test.sh capture-sanitize raw.json > sanitized.json
cmd_capture_sanitize() {
	local fixture_file="${1:-}"
	[ -z "${fixture_file}" ] && die "Usage: bash rtc-test.sh capture-sanitize <fixture.json>"
	[ -f "${fixture_file}" ] || die "File not found: ${fixture_file}"
	command -v php >/dev/null 2>&1 || die "capture-sanitize requires php"

	php "${SCRIPT_DIR}/rtc-helpers.php" capture-sanitize "${fixture_file}"
}

# replay FIXTURE_FILE -- replay a captured session JSON against the current RTC endpoint.
# The fixture is the JSON output from: bash rtc-test.sh capture-export <id> > file.json
#
# Each frame's postType/post:* room updates are sent with a fresh live cursor.
# Captured "after" cursor values are NOT replayed -- they reference a different server
# state; live cursors from each response are used instead.
#
# Env vars:
#   REPLAY_SPEED   Time compression: 1=real-time, 2=2x, 0=instant/no-delay (default: 1)
#   REPLAY_CLIENT  Override client_id for all frames (default: use captured client_id)
cmd_replay() {
	local fixture_file="${1:-}"
	[ -z "${fixture_file}" ] && die "Usage: bash rtc-test.sh replay <fixture.json>"
	[ -f "${fixture_file}" ] || die "File not found: ${fixture_file}"
	command -v php >/dev/null 2>&1 || die "replay requires php to parse fixture JSON"

	local speed="${REPLAY_SPEED:-1}"
	print_header "replay ($(basename "${fixture_file}"), speed=${speed}x)"
	require_auth


	local cursor=0
	local prev_elapsed=0
	local frame_num=0
	local frame_elapsed frame_client frame_updates

	printf 'Parsing fixture and starting replay...\n'

	while IFS=$'\t' read -r frame_elapsed frame_client frame_updates; do
		frame_num=$(( frame_num + 1 ))

		# Timing: sleep proportional to inter-frame elapsed delta at the requested speed.
		# Skipped on the first frame and when REPLAY_SPEED=0 (instant/stress mode).
		if [ "${frame_num}" -gt 1 ] && [ "${speed}" != "0" ]; then
			local delta_ms=$(( frame_elapsed - prev_elapsed ))
			if [ "${delta_ms}" -gt 0 ]; then
				local sleep_s
				sleep_s=$(awk "BEGIN{printf \"%.3f\", ${delta_ms} / (${speed} * 1000)}")
				sleep "${sleep_s}" 2>/dev/null || true
			fi
		fi
		prev_elapsed="${frame_elapsed}"

		# Use captured client_id unless REPLAY_CLIENT is set.
		local cid="${REPLAY_CLIENT:-${frame_client}}"
		local awareness
		awareness="{\"name\":\"RTC-Replay\",\"color\":\"#cc6600\"}"

		local room body resp new_cursor
		room=$(build_room_json "${cid}" "${awareness}" "${cursor}" "${frame_updates}")
		body=$(build_rooms_json "${room}")
		resp=$(rtc_post "replay" "${body}") || true
		new_cursor=$(extract_cursor "${resp}")
		[ -n "${new_cursor}" ] && cursor="${new_cursor}"

		local total_updates compact ui_count uo_count
		total_updates=$(extract_update_count "${resp}")
		compact=$(extract_should_compact "${resp}")
		ui_count=0
		[ -n "${frame_updates}" ] && \
			ui_count=$(printf '%s' "${frame_updates}" | grep -o '"type"' | wc -l | tr -d ' ' || true)
		uo_count=$(printf '%s' "${resp}" | grep -o '"type"' | wc -l | tr -d ' ' || true)

		printf 'frame %3d: t=%5dms ui=%d uo=%s cursor=%s total=%s compact=%s\n' \
			"${frame_num}" "${frame_elapsed}" "${ui_count}" "${uo_count}" \
			"${cursor}" "${total_updates:-0}" "${compact:-false}"

	done < <(php "${SCRIPT_DIR}/rtc-helpers.php" replay-extract "${fixture_file}")

	if [ "${frame_num}" -eq 0 ]; then
		printf 'ERROR: no frames extracted. Check fixture format (expected capture-export JSON).\n' >&2
		return 1
	fi

	printf '\nReplay complete: %d frames sent.\n' "${frame_num}"
	printf 'Run: bash rtc-test.sh report\n'
}

# -------------------------------------------------------------------------
# Dispatch
# -------------------------------------------------------------------------

COMMAND="${1:-}"

case "${COMMAND}" in
	setup)                  cmd_setup ;;
	ensure-wp-version)      cmd_ensure_wp_version ;;
	apply-approach)         cmd_apply_approach "${2:-}" ;;
	reset-approach)         cmd_reset_approach ;;
	teardown)               cmd_teardown ;;
	refresh-auth)           cmd_refresh_auth ;;
	baseline)               cmd_baseline ;;
	single-idle)            cmd_single_idle ;;
	two-idle)               cmd_two_idle ;;
	two-editing)            cmd_two_editing ;;
	one-idle-one-editing)   cmd_one_idle_one_editing ;;
	n-idle)                 cmd_n_idle ;;
	compaction-trigger)     cmd_compaction_trigger ;;
	concurrent)             cmd_concurrent ;;
	sustain)                cmd_sustain ;;
	env)                    cmd_env ;;
	report)                 cmd_report ;;
	report-all)             cmd_report_all ;;
	submit-results)         cmd_submit_results ;;
	clear)                  cmd_clear ;;
	reset)                  cmd_reset ;;
	seed)                   cmd_seed ;;
	capture-start)          cmd_capture_start "${2:-}" ;;
	capture-stop)           cmd_capture_stop ;;
	capture-list)           cmd_capture_list ;;
	capture-export)         cmd_capture_export "${2:-}" ;;
	capture-sanitize)       cmd_capture_sanitize "${2:-}" ;;
	capture-drop)           cmd_capture_drop "${2:-}" ;;
	replay)                 cmd_replay "${2:-}" ;;
	*)
		printf 'Usage: %s <command>\n\n' "$0"
		printf 'Commands:\n'
		printf '  setup                 Auto-configure via WP-CLI (or print manual instructions)\n'
		printf '  ensure-wp-version     Verify WordPress %s is installed; update via WP-CLI if not\n' "${REQUIRED_WP_VERSION}"
		printf '  apply-approach <name> Download nightly, apply approach patch, clear RTC data\n'
		printf '  reset-approach        Download nightly and return to a clean unpatched state\n'
		printf '  teardown              Delete test post, remove cookie jar, strip generated .env section\n'
		printf '  refresh-auth          Re-login and refresh cookie jar + nonce (run if nonce expires)\n'
		printf '  baseline              Measure ambient WP REST overhead (run first)\n'
		printf '  single-idle           1 client, POLLS polls, no updates\n'
		printf '  two-idle              2 clients alternating, awareness propagation\n'
		printf '  two-editing           2 clients: sync handshake + update (1 pass)\n'
		printf '  one-idle-one-editing  1 editor sends updates, 1 idle client watches\n'
		printf '  n-idle                N_CLIENTS clients round-robin, awareness only\n'
		printf '  compaction-trigger    Send updates until compaction fires, then compact\n'
		printf '  concurrent            N_CLIENTS burst simultaneously, POLLS rounds (rendezvous-synced)\n'
		printf '  sustain               N_CLIENTS independent pollers for DURATION seconds\n'
		printf '  env                   Print environment snapshot (PHP, WP, DB, cache, etc.)\n'
		printf '  report                Fetch log from plugin and print summary table\n'
		printf '  report-all            Print summary table grouped by approach × scenario\n'
		printf '  submit-results        POST all results to the reporter endpoint (requires REPORTER_* vars)\n'
		printf '  clear                 Delete all log entries (table stays, schema intact)\n'
		printf '  reset                 Drop the log table entirely (recreated on next tagged request)\n'
		printf '\nCapture commands (require rtc-capture.php in mu-plugins):\n'
		printf '  seed                  Populate POST_ID with 5 lorem ipsum Gutenberg paragraphs\n'
		printf '  capture-start <id>    Start recording /wp-sync/ traffic for POST_ID\n'
		printf '  capture-stop          Stop recording, print frame count\n'
		printf '  capture-list          List all captured sessions\n'
		printf '  capture-export <id>   Print session JSON to stdout (pipe to file)\n'
		printf '  capture-sanitize <f>  Strip responses/awareness from a fixture; print to stdout\n'
		printf '  capture-drop [<id>]   Delete a session (or entire table if no ID given)\n'
		printf '  replay <fixture.json> Replay a captured session JSON against the endpoint\n'
		printf '\nEnvironment variables (set in .env, or pass directly; .env.example shows all options):\n'
		printf '  WP_URL        WordPress site URL (default: http://localhost)\n'
		printf '  WP_USER       WordPress username (set by setup to "rtctest")\n'
		printf '  WP_PASS       WordPress login password (set by setup, used by refresh-auth)\n'
		printf '  WP_COOKIE_JAR Path to cookie jar file (set by setup)\n'
		printf '  WP_NONCE      WP REST API nonce (~12h TTL; refresh with refresh-auth)\n'
		printf '  WP_PATH                Absolute path to WordPress root; required by setup\n'
		printf '  REQUIRED_WP_VERSION    WordPress version to enforce (default: %s)\n' "${REQUIRED_WP_VERSION}"
		printf '  POST_ID       Post ID with edit permission (default: 1)\n'
		printf '  POLLS         Polls per scenario (default: 10)\n'
		printf '  POLL_DELAY    Seconds between polls per client (default: 1; 0=stress/immediate re-poll)\n'
		printf '  N_CLIENTS     Clients for n-idle/concurrent/sustain (default: 3)\n'
		printf '  DURATION      Seconds to run for sustain (default: 30)\n'
		printf '  UPDATE_SIZE   small|medium|large payload (default: small)\n'
		printf '  APPROACH              Storage approach label written to the log (e.g. post-meta, custom-table)\n'
		printf '  REPLAY_SPEED  Replay time compression: 1=real-time 2=2x 0=instant (default: 1)\n'
		printf '  REPLAY_CLIENT Override client_id for replay (default: use captured client_id)\n'
		exit 1
		;;
esac
