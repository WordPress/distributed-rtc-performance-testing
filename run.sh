#!/usr/bin/env bash
# run.sh -- Sets up the test environment and runs the initial RTC performance
# measurement pass (setup → baseline → single-idle → sustain → report), then
# optionally submits results to WordPress.org when WPT_REPORT_API_KEY is set.
#
# Prerequisites: WP_PATH must be set in .env before running.
#
# Optional .env / environment (same as PHPUnit host reporting):
#   WPT_REPORT_API_KEY   Bot credentials as username:password
#   WPT_REPORT_URL       Override destination (default: rtc-performance-results on make.wordpress.org)
#   PTR_ENV_LABEL        Short label stored as env.label on the reporter
#
# Usage:
#   bash run.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -f "${SCRIPT_DIR}/.env" ]; then
	set -a
	# shellcheck source=/dev/null
	. "${SCRIPT_DIR}/.env"
	set +a
fi

bash "${SCRIPT_DIR}/rtc-test.sh" setup
bash "${SCRIPT_DIR}/rtc-test.sh" baseline
bash "${SCRIPT_DIR}/rtc-test.sh" single-idle
bash "${SCRIPT_DIR}/rtc-test.sh" sustain
bash "${SCRIPT_DIR}/rtc-test.sh" report

if [ -n "${WPT_REPORT_API_KEY:-}" ]; then
	bash "${SCRIPT_DIR}/rtc-test.sh" submit-ptr
else
	printf '\nSkipping WordPress.org submission (set WPT_REPORT_API_KEY in .env to upload).\n' >&2
fi
