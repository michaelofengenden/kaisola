#!/usr/bin/env bash
# Deterministic changed-file -> focused native/Node contract runner.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SELECTOR="$ROOT/scripts/native-test-select.cjs"
FOCUSED_NATIVE_RUNNER="$ROOT/scripts/native-test-fast.sh"
RUN_ONLY=0
VERBOSE=0
DRY_RUN=0
declare -a SELECTOR_ARGS=()

usage() {
  /bin/echo "Usage: $0 [change source] [--run-only] [--verbose] [--dry-run]"
  /bin/echo ""
  /bin/echo "Change sources (choose one):"
  /bin/echo "  --changed-file PATH       Explicit repository-relative path; repeatable"
  /bin/echo "  --changed-files-from FILE Read newline-delimited paths (use - for stdin)"
  /bin/echo "  --base REF                Committed REF...HEAD diff"
  /bin/echo "  --staged                  Staged diff"
  /bin/echo "  (default)                 Working-tree and untracked changes"
  /bin/echo ""
  /bin/echo "  --include-working-tree    Add working changes to --base or --staged"
  /bin/echo "  --run-only                Reuse an already-built macOS test product"
  /bin/echo "  --verbose                 Show the full macOS xcodebuild log"
  /bin/echo "  --dry-run                 Print the plan without executing it"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-only)
      RUN_ONLY=1
      ;;
    --verbose)
      VERBOSE=1
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --base|--changed-file|--changed-files-from)
      [[ $# -ge 2 ]] || { /bin/echo "$1 requires a value" >&2; exit 2; }
      SELECTOR_ARGS+=("$1" "$2")
      shift
      ;;
    --staged|--include-working-tree)
      SELECTOR_ARGS+=("$1")
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      /bin/echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

PLAN_FILE="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/kaisola-native-test-plan.XXXXXX")"
cleanup() {
  /bin/rm -f "$PLAN_FILE"
}
trap cleanup EXIT INT TERM

if [[ "${#SELECTOR_ARGS[@]}" -gt 0 ]]; then
  /usr/bin/env node "$SELECTOR" "${SELECTOR_ARGS[@]}" --format json >"$PLAN_FILE"
else
  # macOS ships Bash 3.2, where expanding an empty array under `set -u`
  # raises "unbound variable" instead of producing zero arguments.
  /usr/bin/env node "$SELECTOR" --format json >"$PLAN_FILE"
fi
/usr/bin/env node - "$PLAN_FILE" <<'NODE'
const fs = require('node:fs')
const plan = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
console.log(`Changed files (${plan.changedFiles.length}):`)
for (const file of plan.changedFiles) console.log(`  - ${file}`)
console.log(`Native tests (${plan.native.mode}): ${plan.native.selectors.length ? plan.native.selectors.join(', ') : 'none'}`)
console.log(`Node tests (${plan.node.mode}): ${plan.node.mode === 'focused' ? plan.node.files.join(', ') : plan.node.mode}`)
console.log(`Swift packages: ${plan.swiftPackages.length ? plan.swiftPackages.join(', ') : 'none'}`)
console.log(`Broad fallback: ${plan.fallback ? 'yes' : 'no'}`)
console.log('Selection reasons:')
for (const reason of plan.reasons) console.log(`  - ${reason}`)
NODE

if [[ "$DRY_RUN" -eq 1 ]]; then
  /bin/echo "Dry run: no tests executed."
  exit 0
fi

NODE_MODE="$(/usr/bin/env node -e 'const fs=require("node:fs"); const p=JSON.parse(fs.readFileSync(process.argv[1], "utf8")); process.stdout.write(p.node.mode)' "$PLAN_FILE")"
declare -a NODE_TESTS=()
NODE_TEST_COUNT=0
while IFS= read -r test_file; do
  if [[ -n "$test_file" ]]; then
    NODE_TESTS+=("$test_file")
    NODE_TEST_COUNT=$((NODE_TEST_COUNT + 1))
  fi
done < <(/usr/bin/env node -e 'const fs=require("node:fs"); const p=JSON.parse(fs.readFileSync(process.argv[1], "utf8")); for (const f of p.node.files) console.log(f)' "$PLAN_FILE")

declare -a SWIFT_PACKAGES=()
SWIFT_PACKAGE_COUNT=0
while IFS= read -r package_path; do
  if [[ -n "$package_path" ]]; then
    SWIFT_PACKAGES+=("$package_path")
    SWIFT_PACKAGE_COUNT=$((SWIFT_PACKAGE_COUNT + 1))
  fi
done < <(/usr/bin/env node -e 'const fs=require("node:fs"); const p=JSON.parse(fs.readFileSync(process.argv[1], "utf8")); for (const f of p.swiftPackages) console.log(f)' "$PLAN_FILE")

declare -a NATIVE_TESTS=()
NATIVE_TEST_COUNT=0
while IFS= read -r selector; do
  if [[ -n "$selector" ]]; then
    NATIVE_TESTS+=("$selector")
    NATIVE_TEST_COUNT=$((NATIVE_TEST_COUNT + 1))
  fi
done < <(/usr/bin/env node -e 'const fs=require("node:fs"); const p=JSON.parse(fs.readFileSync(process.argv[1], "utf8")); for (const f of p.native.selectors) console.log(f)' "$PLAN_FILE")

if [[ "$NODE_MODE" == "all" ]]; then
  /bin/echo "Running all Node contracts…"
  (cd "$ROOT" && /usr/bin/env npm run test:node)
elif [[ "$NODE_MODE" == "focused" ]]; then
  /bin/echo "Running focused Node contracts: ${NODE_TESTS[*]}"
  (cd "$ROOT" && /usr/bin/env node --test "${NODE_TESTS[@]}")
fi

if [[ "$SWIFT_PACKAGE_COUNT" -gt 0 ]]; then
  for package_path in "${SWIFT_PACKAGES[@]}"; do
    # SwiftPM's Clang module cache embeds absolute paths and cannot be reused
    # after the repository is moved. Key the scratch directory by the current
    # canonical package path so a move gets a clean cache automatically while
    # ordinary runs continue to be incremental.
    package_name="$(basename "$package_path")"
    package_cache_key="$(printf '%s' "$ROOT/$package_path" | shasum -a 256 | awk '{ print substr($1, 1, 12) }')"
    package_scratch="$ROOT/.build/swift-package-tests/${package_name}-${package_cache_key}"
    /bin/echo "Running Swift package contracts: $package_path"
    (cd "$ROOT" && /usr/bin/env swift test \
      --package-path "$package_path" \
      --scratch-path "$package_scratch")
  done
fi

if [[ "$NATIVE_TEST_COUNT" -gt 0 ]]; then
  declare -a NATIVE_ARGS=()
  [[ "$RUN_ONLY" -eq 1 ]] && NATIVE_ARGS+=("--run-only")
  [[ "$VERBOSE" -eq 1 ]] && NATIVE_ARGS+=("--verbose")
  NATIVE_ARGS+=("${NATIVE_TESTS[@]}")
  "$FOCUSED_NATIVE_RUNNER" "${NATIVE_ARGS[@]}"
fi

if [[ "$NODE_MODE" == "none" && "$SWIFT_PACKAGE_COUNT" -eq 0 && "$NATIVE_TEST_COUNT" -eq 0 ]]; then
  /bin/echo "No runtime tests selected: every changed file is explicitly classified as documentation-only."
else
  /bin/echo "Changed-file test lane passed."
fi
