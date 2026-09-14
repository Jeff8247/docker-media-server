#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_dir/scripts/update-containers.sh"

failures=0
assert_contains() {
  local output="$1" expected="$2" name="$3"
  if [[ "$output" == *"$expected"* ]]; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s (missing %q)\n' "$name" "$expected"
    failures=$((failures + 1))
  fi
}

assert_contains "$(<"$script")" 'COMPOSE_PARALLEL_LIMIT="$pull_parallel_limit" docker compose pull' 'pull concurrency is bounded'
assert_contains "$(<"$script")" 'PULL_MAX_ATTEMPTS:-4' 'initial attempt plus three retries'
assert_contains "$(<"$script")" 'PULL_RETRY_DELAYS:-30 90 180' 'retry backoff is configured'
assert_contains "$(<"$repo_dir/systemd/mediaserver-update.service")" 'ExecStart=/usr/local/sbin/mediaserver-update' 'systemd runs root-owned updater copy'
assert_contains "$(<"$repo_dir/systemd/mediaserver-update.timer")" 'RandomizedDelaySec=15min' 'timer has registry-load jitter'

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export MOCK_STATE_DIR="$tmp"
export MOCK_PULL_SUCCEED_ON=4
export MEDIASERVER_PROJECT_DIR="$repo_dir"
export PULL_MAX_ATTEMPTS=4
export PULL_RETRY_DELAYS='0 0 0'
export PULL_PARALLEL_LIMIT=4
export UPDATE_LOCK_FILE="$tmp/update.lock"
PATH="$repo_dir/tests/fixtures/update-bin:$PATH" "$script" >"$tmp/output" 2>&1
[[ "$(<"$tmp/pull-count")" == 4 ]] || { echo 'FAIL: updater did not make four bounded attempts'; failures=$((failures + 1)); }
[[ "$(sort -u "$tmp/parallel-limits")" == 4 ]] || { echo 'FAIL: pull concurrency was not passed to Compose'; failures=$((failures + 1)); }
[[ "$(paste -sd, "$tmp/sleeps")" == '0,0,0' ]] || { echo 'FAIL: updater did not apply all retry delays'; failures=$((failures + 1)); }
assert_contains "$(<"$tmp/output")" 'Pull attempt 4/4' 'pull succeeds after three transient failures'

if ((failures)); then
  printf '%d test(s) failed\n' "$failures" >&2
  exit 1
fi
echo 'All updater tests passed.'
