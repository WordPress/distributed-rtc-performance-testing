# rtc-test

Load-testing tool for the WordPress Real Time Collaboration HTTP polling endpoint
(`POST /wp-sync/v1/updates`).

Two files:

| File | Where it goes |
|---|---|
| `rtc-test.php` | `wp-content/mu-plugins/` on the test site |
| `rtc-test.sh` | Anywhere you want to run tests from |

Requirements: **bash**, **curl**. WP-CLI is used by `setup`/`teardown` if available.
`replay` and `capture-sanitize` also require **python3**.

---

## Installation

Copy `rtc-test.php` into the site's `mu-plugins` directory. No activation needed.

Verify it loaded:

```
Tools > RTC Tests
```

---

## Setup

Run `setup` on the web host (WP-CLI creates the test user and post):

```bash
bash rtc-test.sh setup
```

This writes `rtc-test.env` with the site URL, credentials, and a test post ID.

**Running tests from a different host (e.g. your laptop):**

```bash
# On the web host after setup:
cat rtc-test.env

# Paste the output into rtc-test.env on your local machine, then:
bash rtc-test.sh refresh-auth   # creates local cookie jar + fresh nonce (required after copy)
bash rtc-test.sh baseline
# Nonces expire after ~12h; refresh-auth renews them.
```

---

## Initial report

```bash
bash rtc-test.sh baseline          # ambient WP REST overhead (no RTC)
bash rtc-test.sh single-idle       # 1 client, 10 polls, no updates
bash rtc-test.sh sustain           # 3 clients polling for 30s (default)
bash rtc-test.sh report            # print summary table
```

The report shows per-scenario means for `disp_ms` (endpoint wall time),
`total_ms` (full worker occupancy), `cpu_ms`, DB queries, and max concurrency.

---

## Common variants

**More clients, longer run:**

```bash
N_CLIENTS=8 DURATION=60 bash rtc-test.sh sustain
```

**Stress mode (no delay between polls):**

```bash
N_CLIENTS=10 POLL_DELAY=0 DURATION=20 bash rtc-test.sh sustain
```

**Burst concurrency (all clients fire simultaneously):**

```bash
N_CLIENTS=8 POLLS=10 bash rtc-test.sh concurrent
```

**Compaction cycle:**

```bash
bash rtc-test.sh compaction-trigger
```

**Two clients exchanging edits (sync handshake):**

```bash
bash rtc-test.sh two-editing
```

**Clear log between runs:**

```bash
bash rtc-test.sh clear     # delete rows, keep table
bash rtc-test.sh reset     # drop and recreate table
```

---

## Capturing and replaying real sessions

Capture a real browser editing session as a replay fixture:

```bash
bash rtc-test.sh seed                          # populate the test post with content
bash rtc-test.sh capture-start my-session      # start recording
# Open the editor in a browser and edit the post
bash rtc-test.sh capture-stop                  # stop recording
bash rtc-test.sh capture-export my-session > captures/my-session.json
```

Sanitize the fixture for sharing (strips awareness names, cursors, response bodies):

```bash
bash rtc-test.sh capture-sanitize captures/my-session.json \
  > captures/my-session-sanitized.json
```

Replay against the current site:

```bash
bash rtc-test.sh replay captures/my-session.json            # real-time
REPLAY_SPEED=4 bash rtc-test.sh replay captures/my-session.json  # 4x
REPLAY_SPEED=0 bash rtc-test.sh replay captures/my-session.json  # instant
```

---

## Teardown

```bash
bash rtc-test.sh teardown   # deletes test post, removes rtc-test.env and cookie jar
```

The `rtctest` user is left in place (password was randomized by setup).
