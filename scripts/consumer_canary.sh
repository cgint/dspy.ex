#!/usr/bin/env bash
#
# scripts/consumer_canary.sh — prove each consumer app still compiles against THIS local
# dspy.ex checkout, without touching the consumer checkouts.
#
# Usage:
#   scripts/consumer_canary.sh [--test] [consumer ...]
#
#   consumer ...          Names of consumers to run (default: all 5).
#                         A consumer name may also be an absolute/relative path to a
#                         consumer root (must contain mix.exs).
#   --test                Additionally run `mix test` in the copy (report-only; does
#                         not fail the canary). Network/integration tagged tests are
#                         excluded if the consumer defines such tags.
#
# Env:
#   CANARY_CONSUMERS_ROOT  Root dir containing the consumer checkouts
#                         (default: /Users/cgint/dev)
#
# Per consumer: ALLOWLIST-copy the consumer root into tmp/canary/<name>/ — only
#   mix.exs, mix.lock, .formatter.exs, lib/, config/, test/, rel/, priv/ (WITHOUT
#   top-level priv/static), and deps/ COMPLETE (dep priv files stay intact), then
#   drop deps/dspy. Secret excludes are root-anchored (/.env*, /*.pem, /*.key,
#   /secrets*) plus config/*.secret.exs and config/.env* (config/ is always copied).
#   Then rewrite the dspy dep in the COPY's mix.exs to
#   `{:dspy, path: "<this repo>", override: true}` and run
#   MIX_ENV=test mix deps.get && mix compile --warnings-as-errors.
# Logs go to tmp/canary/<name>.log. Exits non-zero if any consumer's compile fails
# (on failure, a baseline run with the ORIGINAL dep in tmp/canary/<name>-baseline
# classifies the failure as dspy-caused vs pre-existing).
#
# Safety: only writes inside this repo's tmp/canary/ and tmp/canary/rewrites.
#         Never prints env/secret contents (secrets are excluded from the copy).
#
# NOTE on the copy: rsync with a bare destination dir (e.g. `rsync -a src/ dest/`)
# can land the source contents flat in dest (without the source dir name) on this
# machine. To be robust, each source dir is explicitly copied into a matching
# named subdir in the destination (e.g. `rsync -a src/lib/ dest/lib/`), which
# preserves the dir boundary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONSUMERS_ROOT="${CANARY_CONSUMERS_ROOT:-/Users/cgint/dev}"
CANARY_DIR="$REPO_ROOT/tmp/canary"
REWRITE_DIR="$CANARY_DIR/rewrites"
ALL_CONSUMERS=(agent-coding-gui elix-live-chat third-eye-liveview finance-partner my-speech-google)

RUN_TEST=0
args=()
for arg in "$@"; do
  case "$arg" in
    --test) RUN_TEST=1 ;;
    -*) echo "Unknown option: $arg" >&2; exit 2 ;;
    *) args+=("$arg") ;;
  esac
done
if [ "${#args[@]}" -eq 0 ]; then
  consumers=("${ALL_CONSUMERS[@]}")
else
  consumers=("${args[@]}")
fi

mkdir -p "$CANARY_DIR" "$REWRITE_DIR"

# Sanity: this repo must be a dspy checkout with mix.exs.
if [ ! -f "$REPO_ROOT/mix.exs" ]; then
  echo "FATAL: no mix.exs found at $REPO_ROOT (bad REPO_ROOT?)" >&2
  exit 1
fi

log_fail() { # log_fail <name> <log>
  echo "---- last 25 lines of $2 ----"
  tail -n 25 "$2" || true
}

# Record result (drives the final exit code).
RESULTS=()
log_result() { # log_result <name> <status> <log-or-empty>
  RESULTS+=("$1=$2")
}

# canary_copy <root> <dest>
# Allowlist-copy the consumer root into dest. Each source dir is explicitly
# copied into a matching named subdir in dest (to preserve the dir boundary).
# Secret excludes are ROOT-ANCHORED (they only match at the consumer root; dep
# trees like deps/certifi/priv/cacerts.pem are untouched) plus the config/
# secret forms (config/ is always copied):
#   /.env*  /*.pem  /*.key  /secrets*  /config/*.secret.exs  /config/.env*
# A missing non-optional item (mix.exs, mix.lock, lib/, test/) fails loudly.
# _build/, node_modules/, .elixir_ls/, .git/ never enter (not in the allowlist).
canary_copy() {
  local root="$1" dest="$2"
  rm -rf "$dest"
  mkdir -p "$dest"
  local excludes=(
    --exclude="/.env*"
    --exclude="/*.pem"
    --exclude="/*.key"
    --exclude="/secrets*"
    --exclude="/config/*.secret.exs"
    --exclude="/config/.env*"
  )
  local rc=0
  local rsync_err
  # Optional top-level files.
  if [ -f "$root/.formatter.exs" ]; then
    if ! rsync_err=$(rsync -a "${excludes[@]}" "$root/.formatter.exs" "$dest/" 2>&1); then
      echo "    rsync error: $rsync_err" >&2; rc=1
    fi
  fi
  # Required top-level files (mix.exs, mix.lock).
  if [ -f "$root/mix.exs" ] && [ -f "$root/mix.lock" ]; then
    if ! rsync_err=$(rsync -a "${excludes[@]}" "$root/mix.exs" "$root/mix.lock" "$dest/" 2>&1); then
      echo "    rsync error: $rsync_err" >&2; rc=1
    fi
  else
    echo "    rsync error: mix.exs or mix.lock missing in $root" >&2; rc=1
  fi
  # Required directories: copy each into a matching named subdir in dest.
  if [ -d "$root/lib" ]; then
    if ! rsync_err=$(rsync -a "${excludes[@]}" "$root/lib/" "$dest/lib/" 2>&1); then
      echo "    rsync error: $rsync_err" >&2; rc=1
    fi
  else
    echo "    rsync error: lib/ missing in $root" >&2; rc=1
  fi
  if [ -d "$root/test" ]; then
    if ! rsync_err=$(rsync -a "${excludes[@]}" "$root/test/" "$dest/test/" 2>&1); then
      echo "    rsync error: $rsync_err" >&2; rc=1
    fi
  else
    echo "    rsync error: test/ missing in $root" >&2; rc=1
  fi
  # Config: always copied, secrets excluded.
  if ! rsync_err=$(rsync -a "${excludes[@]}" "$root/config/" "$dest/config/" 2>&1); then
    echo "    rsync error: $rsync_err" >&2; rc=1
  fi
  # priv: only if present, without top-level priv/static.
  # (The nested --exclude "static" matches priv/static because the item root is priv/.)
  if [ -d "$root/priv" ]; then
    if ! rsync_err=$(rsync -a "${excludes[@]}" --exclude="static" "$root/priv/" "$dest/priv/" 2>&1); then
      echo "    rsync error: $rsync_err" >&2; rc=1
    fi
  fi
  # rel: only if present.
  if [ -d "$root/rel" ]; then
    if ! rsync_err=$(rsync -a "${excludes[@]}" "$root/rel/" "$dest/rel/" 2>&1); then
      echo "    rsync error: $rsync_err" >&2; rc=1
    fi
  fi
  # deps: COMPLETE (dep priv files stay intact), except deps/dspy (handled below).
  if [ -d "$root/deps" ]; then
    if ! rsync_err=$(rsync -a "${excludes[@]}" --exclude="dspy" "$root/deps/" "$dest/deps/" 2>&1); then
      echo "    rsync error: $rsync_err" >&2; rc=1
    fi
    rm -rf "$dest/deps/dspy"
  fi
  if [ "$rc" -ne 0 ]; then
    echo "    COPY FAILED: one or more rsync items failed for $root" >&2
    return 1
  fi
  # Verify the allowlist did what we promised.
  [ -f "$dest/mix.exs" ] && [ -f "$dest/mix.lock" ] && \
    [ -d "$dest/lib" ] && [ -d "$dest/test" ] && [ -d "$dest/config" ] && \
    [ -f "$dest/test/test_helper.exs" ] || {
      echo "    COPY VERIFY FAILED: required paths missing in $dest" >&2
      ls -la "$dest" >&2 || true
      return 1
    }
  return 0
}

# rewrite_mix_exs <src-mix.exs> <name>
# Replace the dspy dep line(s) with a path dep + override. Uses the Ruby regex
# engine (multiline mode) so both single-line and multi-line {:dspy, ...} forms
# are handled. Exits non-zero if the rewrite is not detectably applied.
rewrite_mix_exs() {
  local mix="$1" name="$2"
  local ruby='
    src = File.read(ARGV[0])
    dst = ARGV[1]
    dep = "{:dspy, path: \"" + ARGV[2] + "\", override: true}"
    out = src.sub(%r/\{\s*:dspy\s*,[^{}]*?\}\s*,?/m, dep + ",")
    unless out != src
      warn "dspy dep not found in " + ARGV[0]
      exit 1
    end
    if out !~ /\{\s*:dspy\s*,\s*path:\s*"/
      warn "rewrite did not produce a path dep in " + ARGV[0]
      exit 1
    end
    File.write(ARGV[1], out)
  '
  if ruby_out=$(ruby -e "$ruby" "$mix" "$REWRITE_DIR/$name" "$REPO_ROOT" 2>&1); then
    :
  else
    echo "    REWRITE FAILED: $ruby_out" >&2
    return 1
  fi
  cp "$REWRITE_DIR/$name" "$mix"
}

# extract_consumer_warnings <log>
# Extract warning entries for the CONSUMER project only. Each entry is
# "<location> :: <message>" where location is a `└─ lib/...` or `└─ test/...`
# reference and message is the first `warning: ...` line that precedes it.
# Dependency warnings (e.g. └─ deps/...) are NOT included.
extract_consumer_warnings() {
  local log="$1"
  ruby -e '
    lines = File.read(ARGV[0]).lines.map { |l| l.chomp }
    entries = []
    i = 0
    while i < lines.length
      l = lines[i]
      if l =~ /└─\s+((?:lib|test)\/\S+?)(?::(\d+))?/ 
        loc = Regexp.last_match(1)
        line = Regexp.last_match(2) || ""
        # Walk backwards to find the nearest preceding `warning:` line.
        j = i - 1
        msg = "(no message)"
        while j >= 0
          bl = lines[j]
          if bl =~ /warning:\s*(.+)/ 
            msg = Regexp.last_match(1).strip
            break
          end
          # Stop at the previous └─ ref or a blank line followed by └─.
          break if bl =~ /└─/ 
          j -= 1
        end
        entries << "#{loc}#{line ? ":#{line}" : ""} :: #{msg}"
      end
      i += 1
    end
    puts entries
  ' "$log"
}

# dspy_warnings_in <log>
# Print any warning whose text mentions Dspy (case-insensitive).
dspy_warnings_in() {
  local log="$1"
  grep -inE "warning:.*dspy" "$log" 2>/dev/null || true
}

# classify_warnings <name> <canary-log> <base-log> <canary-dir> <base-dir>
# When both canary and baseline failed --warnings-as-errors, re-compile both
# WITHOUT --warnings-as-errors (project only, --force) to check for hard errors,
# then diff consumer-project warnings.
# Returns: 0 = WARN-BASELINE (identical warnings), 1 = FAIL (hard error or
# new warnings).
# Sets global: CLASSIFY_MESSAGE (description for the report).
classify_warnings() {
  local name="$1" clog="$2" blog="$3" cdir="$4" bdir="$5"
  local cwarn bwarn diff_new diff_base
  local ccompile bcompile

  # Re-compile canary WITHOUT --warnings-as-errors (project only, --force).
  echo "[$name] re-compiling canary without --warnings-as-errors (project only, --force)"
  if ( cd "$cdir" && MIX_ENV=test mix compile --force ) >"$clog.soft" 2>&1; then
    ccompile=0
  else
    ccompile=1
  fi

  # Re-compile baseline WITHOUT --warnings-as-errors (project only, --force).
  echo "[$name] re-compiling baseline without --warnings-as-errors (project only, --force)"
  if ( cd "$bdir" && MIX_ENV=test mix compile --force ) >"$blog.soft" 2>&1; then
    bcompile=0
  else
    bcompile=1
  fi

  # Hard error check: if either soft compile failed, it is a hard compile error.
  if [ "$ccompile" -ne 0 ] || [ "$bcompile" -ne 0 ]; then
    if [ "$ccompile" -ne 0 ]; then
      echo "    HARD COMPILE ERROR in canary (soft compile failed)"
      tail -n 20 "$clog.soft" || true
    fi
    if [ "$bcompile" -ne 0 ]; then
      echo "    HARD COMPILE ERROR in baseline (soft compile failed)"
      tail -n 20 "$blog.soft" || true
    fi
    CLASSIFY_MESSAGE="hard compile error"
    return 1
  fi

  # Extract consumer-project warnings from the soft-compile logs.
  cwarn=$(extract_consumer_warnings "$clog.soft")
  bwarn=$(extract_consumer_warnings "$blog.soft")

  # Diff: warnings present only in canary = new warnings (dspy-caused).
  diff_new=$(comm -23 <(echo "$cwarn" | sort -u) <(echo "$bwarn" | sort -u) | grep -v '^$' || true)
  # Warnings present only in baseline = removed by the new dspy (informational).
  diff_base=$(comm -13 <(echo "$cwarn" | sort -u) <(echo "$bwarn" | sort -u) | grep -v '^$' || true)

  local ccount bcount
  ccount=$(echo "$cwarn" | grep -c '.' || true)
  bcount=$(echo "$bwarn" | grep -c '.' || true)

  # Always print any canary warning whose text mentions Dspy.
  local dspy_refs
  dspy_refs=$(dspy_warnings_in "$clog.soft")
  if [ -n "$dspy_refs" ]; then
    echo "    CANARY warnings mentioning Dspy:"
    echo "$dspy_refs" | sed 's/^/      /'
  fi

  if [ -n "$diff_new" ]; then
    echo "    NEW warnings in canary (not in baseline) — dspy-caused:"
    echo "$diff_new" | sed 's/^/      /'
    CLASSIFY_MESSAGE="new warnings: $(echo "$diff_new" | wc -l | tr -d ' ')"
    return 1
  fi

  if [ -n "$diff_base" ]; then
    echo "    $(echo "$diff_base" | wc -l | tr -d ' ') warning(s) present in baseline but not in canary (fixed by new dspy):"
    echo "$diff_base" | head -10 | sed 's/^/      /'
    [ "$(echo "$diff_base" | wc -l | tr -d ' ')" -gt 10 ] && echo "      ... and $(($(echo "$diff_base" | wc -l | tr -d ' ') - 10)) more"
  fi

  local total
  total=$(echo "$cwarn" | grep -c '.' || true)
  echo "    WARN-BASELINE: $total consumer warning(s) identical to baseline (canary=$ccount, baseline=$bcount)"
  CLASSIFY_MESSAGE="warn-baseline ($total warnings)"
  return 0
}

run_consumer() {
  local name="$1" root="$2"
  local dest="$CANARY_DIR/$name"
  local log="$CANARY_DIR/$name.log"
  local t_start

  if [ ! -f "$root/mix.exs" ]; then
    echo "[$name] SKIP: no mix.exs at $root"
    log_result "$name" "FAIL(no mix.exs)" ""
    return 0
  fi

  t_start=$(date +%s)

  echo "[$name] allowlist copy -> $dest (root: $root)"
  if ! canary_copy "$root" "$dest"; then
    log_result "$name" "FAIL(copy)" ""
    return 0
  fi

  # Rewrite the dspy dep in the COPY only.
  if ! rewrite_mix_exs "$dest/mix.exs" "$name"; then
    log_result "$name" "FAIL(rewrite)" "$log"
    return 0
  fi
  # grep-verify the rewrite landed in the copy
  if ! grep -qF '{:dspy, path: "'$REPO_ROOT'"' "$dest/mix.exs"; then
    echo "    VERIFY FAILED: rewritten mix.exs does not point at $REPO_ROOT" >&2
    log_result "$name" "FAIL(rewrite-verify)" "$log"
    return 0
  fi

  echo "[$name] MIX_ENV=test mix deps.get + mix compile --warnings-as-errors"
  if ( cd "$dest" && \
      MIX_ENV=test mix deps.get >"$log" 2>&1 && \
      MIX_ENV=test mix compile --warnings-as-errors >>"$log" 2>&1 ); then
    echo "[$name] COMPILE OK"
    compile_ok=1
  else
    echo "[$name] COMPILE FAILED (log: $log)"
    log_fail "$name" "$log"
    compile_ok=0
  fi

  if [ "$RUN_TEST" -eq 1 ] && [ "$compile_ok" -eq 1 ]; then
    # Exclude network/integration tags if the consumer defines them.
    local tagdefs
    tagdefs=$(grep -REoh 'excluded_tags: ?\[[^]]*\]|tags: ?\{[^}]*\}' "$dest/config" 2>/dev/null | head -n 10 || true)
    local test_args=(MIX_ENV=test mix test)
    for tag in network integration; do
      if echo "$tagdefs" | grep -q "[:$tag]"; then
        test_args+=("--exclude" "test.$tag")
      fi
    done
    echo "[$name] ${test_args[*]} (report-only)"
    if ( cd "$dest" && "${test_args[@]}" >>"$log" 2>&1 ); then
      echo "[$name] TEST OK"
    else
      echo "[$name] TEST FAILED (report-only, not failing the canary; see $log)"
    fi
  fi

  local dur=$(( $(date +%s) - t_start ))
  echo "[$name] done in ${dur}s (size: $(du -sh "$dest" 2>/dev/null | cut -f1))"

  if [ "$compile_ok" -eq 1 ]; then
    log_result "$name" "PASS" "$log"
  else
    # Classify: re-run with the ORIGINAL dep untouched to see if the failure is
    # pre-existing at the consumer's own pin.
    echo "[$name] classifying: baseline run with original dep (tmp/canary/$name-baseline)"
    local base="$CANARY_DIR/$name-baseline"
    local base_log="$CANARY_DIR/$name-baseline.log"
    if ! canary_copy "$root" "$base"; then
      log_result "$name" "FAIL(copy-baseline)" ""
      return 0
    fi
    if ( cd "$base" && \
        MIX_ENV=test mix deps.get >"$base_log" 2>&1 && \
        MIX_ENV=test mix compile --warnings-as-errors >>"$base_log" 2>&1 ); then
      echo "[$name] BASELINE OK -> failure is DSPY-CAUSED (this checkout broke it)"
      log_result "$name" "FAIL(dspy-caused)" "$log"
    else
      # Both canary and baseline failed --warnings-as-errors.
      # Re-classify: re-compile both WITHOUT --warnings-as-errors, check for
      # hard errors, then diff consumer-project warnings.
      if classify_warnings "$name" "$log" "$base_log" "$dest" "$base"; then
        log_result "$name" "WARN-BASELINE" "$log"
      else
        log_result "$name" "FAIL(new-warnings: ${CLASSIFY_MESSAGE:-unclassified})" "$log"
      fi
    fi
  fi
}

for name in "${consumers[@]}"; do
  root="$CONSUMERS_ROOT/$name"
  if [ -d "$root" ]; then
    run_consumer "$name" "$root"
  elif [ -d "$name" ]; then
    # allow an explicit path argument
    root="$(cd "$name" && pwd)"
    run_consumer "$name" "$root"
  else
    echo "[$name] FAIL: consumer root not found: $root (set CANARY_CONSUMERS_ROOT?)"
    log_result "$name" "FAIL(not-found)" ""
  fi
done

echo
echo "=================== CANARY SUMMARY ==================="
overall=0
for r in "${RESULTS[@]}"; do
  name="${r%%=*}"
  status="${r#*=}"
  printf '  %-18s %s\n' "$name" "$status"
  case "$status" in
    PASS*|WARN-BASELINE*) ;;
    *) overall=1 ;; # any FAIL fails the canary; WARN-BASELINE counts as pass
  esac
done
echo "======================================================="

exit "$overall"
