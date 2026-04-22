#!/usr/bin/env bash
# run.sh -- Sets up the test environment, runs the full RTC performance suite
# across all four storage approaches, prints a combined report, and submits
# results to the reporter endpoint.
#
# Prerequisites: WP_PATH (and optionally REPORTER_URL + reporter credentials)
# must be set in .env before running.
#
# Usage:
#   bash run.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RTC="${SCRIPT_DIR}/rtc-test.sh"

# ── One-time setup ────────────────────────────────────────────────────────────
# Installs the MU-plugin, creates the rtctest user and test post, verifies the
# required WordPress version, and writes credentials to .env.
bash "${RTC}" setup

# ── Per-approach test loop ────────────────────────────────────────────────────
# For each approach: patch WP, reset RTC state, run the scenario suite.
# APPROACH is passed as an env var so every log entry is tagged with the name.

APPROACHES="post-meta custom-table post-meta-transients custom-table-with-transients"

for approach in ${APPROACHES}; do
	bash "${RTC}" apply-approach "${approach}"

	# Clear log entries from any previous approach so report-all has clean data.
	APPROACH="${approach}" bash "${RTC}" clear

	APPROACH="${approach}" bash "${RTC}" baseline
	APPROACH="${approach}" bash "${RTC}" single-idle
	APPROACH="${approach}" bash "${RTC}" sustain
done

# ── Reset to RC2 baseline after the final approach ────────────────────────────
bash "${RTC}" reset-approach

# ── Results ───────────────────────────────────────────────────────────────────
bash "${RTC}" report-all
bash "${RTC}" submit-results
