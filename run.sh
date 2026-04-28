#!/usr/bin/env bash
# run.sh -- Sets up the test environment, runs the full RTC performance suite
# across all five storage approaches, prints a combined report, and submits
# results to the reporter endpoint.
#
# Prerequisites: WP_PATH (and optionally REPORTER_URL + reporter credentials)
# must be set in .env before running.
#
# Parameter matrix (per approach, after apply-approach):
#   Default: POLL_DELAY in {0,1} and UPDATE_SIZE in {small, medium, large} (6 combos).
#   Pinning: if POLL_DELAY and/or UPDATE_SIZE are already set in the environment
#   before this script runs, only that value is used for that axis (same rule as rtc-test.sh).
#   Override lists: RTC_MATRIX_POLL_DELAYS="0 1" and/or RTC_MATRIX_UPDATE_SIZES="small large"
#   (space-separated). Used only for an axis that is not pinned.
#
# Usage:
#   bash run.sh

set -euo pipefail

die() { printf 'ERROR: run.sh: %s\n' "$1" >&2; exit 1; }

# Validate space-separated matrix tokens (same rules as rtc-test.sh) before any curl runs.
_matrix_validate_poll_delays() {
	local t out=""
	for t in $1; do
		case "${t}" in
			''|*[!0-9]*) die "invalid POLL_DELAY matrix token: ${t}" ;;
		esac
		[ "${t}" -le 86400 ] 2>/dev/null || die "invalid POLL_DELAY matrix token (max 86400): ${t}"
		out="${out}${out:+ }${t}"
	done
	[ -n "${out}" ] || die "POLL_DELAY matrix resolved to an empty list"
	printf '%s' "${out}"
}

_matrix_validate_update_sizes() {
	local t out=""
	for t in $1; do
		case "${t}" in
			small|medium|large) out="${out}${out:+ }${t}" ;;
			*) die "invalid UPDATE_SIZE matrix token: ${t}" ;;
		esac
	done
	[ -n "${out}" ] || die "UPDATE_SIZE matrix resolved to an empty list"
	printf '%s' "${out}"
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RTC="${SCRIPT_DIR}/rtc-test.sh"
ENV_FILE="${SCRIPT_DIR}/.env"

# Snapshot POLL_DELAY / UPDATE_SIZE before .env so exported values win over the file.
_pre_pin_poll=0
[ "${POLL_DELAY+x}" = x ] && _pre_pin_poll=1 && _pre_poll="${POLL_DELAY}"
_pre_pin_sz=0
[ "${UPDATE_SIZE+x}" = x ] && _pre_pin_sz=1 && _pre_sz="${UPDATE_SIZE}"

# Source .env without exporting (no `set -a`). Exporting WP_NONCE here would stick in this
# shell after `setup` rewrites .env; child `bash rtc-test.sh` processes would inherit the stale
# nonce and rtc-test.sh would restore it over the file — REST calls fail with rest_cookie_invalid_nonce.
if [ -f "${ENV_FILE}" ]; then
	# shellcheck source=/dev/null
	. "${ENV_FILE}"
fi

[ "${_pre_pin_poll}" = 1 ] && POLL_DELAY="${_pre_poll}"
[ "${_pre_pin_sz}" = 1 ] && UPDATE_SIZE="${_pre_sz}"

if [ "${_pre_pin_poll}" = 1 ]; then
	RTC_POLL_DELAYS="${POLL_DELAY}"
elif [ -n "${RTC_MATRIX_POLL_DELAYS:-}" ]; then
	RTC_POLL_DELAYS="${RTC_MATRIX_POLL_DELAYS}"
else
	RTC_POLL_DELAYS="0 1"
fi

if [ "${_pre_pin_sz}" = 1 ]; then
	RTC_UPDATE_SIZES="${UPDATE_SIZE}"
elif [ -n "${RTC_MATRIX_UPDATE_SIZES:-}" ]; then
	RTC_UPDATE_SIZES="${RTC_MATRIX_UPDATE_SIZES}"
else
	RTC_UPDATE_SIZES="small medium large"
fi

RTC_POLL_DELAYS="$(_matrix_validate_poll_delays "${RTC_POLL_DELAYS}")"
RTC_UPDATE_SIZES="$(_matrix_validate_update_sizes "${RTC_UPDATE_SIZES}")"

unset _pre_pin_poll _pre_poll _pre_pin_sz _pre_sz

# Drop auth vars from this shell so every rtc-test.sh child reads them from .env only.
# (Avoids stale WP_NONCE inherited from the parent process after setup rewrites the file.)
unset WP_NONCE WP_COOKIE_JAR 2>/dev/null || true

# ── One-time setup ────────────────────────────────────────────────────────────
# Installs the MU-plugin, creates the rtctest user and test post, verifies the
# required WordPress version, and writes credentials to .env.
bash "${RTC}" setup

# ── Clear any log data from previous runs ─────────────────────────────────────
# report-all and submit-results aggregate everything in the log table, so stale
# rows from a prior run would skew the averages. Clear before each full suite.
bash "${RTC}" clear

# ── Environment snapshot ──────────────────────────────────────────────────────
bash "${RTC}" env

# ── Per-approach test loop ────────────────────────────────────────────────────
# For each approach: patch WP, reset RTC state, then run baseline / single-idle /
# sustain for every (POLL_DELAY × UPDATE_SIZE) combination.

APPROACHES="post-meta custom-table post-meta-transients custom-table-with-transients custom-tables-with-presence"

printf '\n── Matrix: POLL_DELAY ∈ {%s}, UPDATE_SIZE ∈ {%s} ──\n' \
	"${RTC_POLL_DELAYS// /, }" "${RTC_UPDATE_SIZES// /, }"

for approach in ${APPROACHES}; do
	bash "${RTC}" apply-approach "${approach}"

	for poll_delay in ${RTC_POLL_DELAYS}; do
		for update_size in ${RTC_UPDATE_SIZES}; do
			APPROACH="${approach}" POLL_DELAY="${poll_delay}" UPDATE_SIZE="${update_size}" \
				bash "${RTC}" print-test-conditions "${approach}"
			APPROACH="${approach}" POLL_DELAY="${poll_delay}" UPDATE_SIZE="${update_size}" \
				bash "${RTC}" baseline
			APPROACH="${approach}" POLL_DELAY="${poll_delay}" UPDATE_SIZE="${update_size}" \
				bash "${RTC}" single-idle
			APPROACH="${approach}" POLL_DELAY="${poll_delay}" UPDATE_SIZE="${update_size}" \
				bash "${RTC}" sustain
		done
	done
done

# ── Reset to RC2 baseline after the final approach ────────────────────────────
bash "${RTC}" reset-approach

# ── Results ───────────────────────────────────────────────────────────────────
bash "${RTC}" report-all
bash "${RTC}" submit-results
