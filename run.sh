#!/usr/bin/env bash
# run.sh -- Sets up the test environment and runs the initial RTC performance
# measurement pass (setup → baseline → single-idle → sustain → report).
#
# Prerequisites: WP_PATH must be set in .env before running.
#
# Usage:
#   bash run.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

bash "${SCRIPT_DIR}/rtc-test.sh" setup
bash "${SCRIPT_DIR}/rtc-test.sh" baseline
bash "${SCRIPT_DIR}/rtc-test.sh" single-idle
bash "${SCRIPT_DIR}/rtc-test.sh" sustain
bash "${SCRIPT_DIR}/rtc-test.sh" report
