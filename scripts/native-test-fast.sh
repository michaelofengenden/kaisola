#!/usr/bin/env bash
# Focused native test runner sharing the fast development DerivedData cache.
# Refuses an empty selector so an accidental command cannot start the full suite.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PROJECT="$ROOT/native/KaisolaMac/KaisolaMac.xcodeproj"
DERIVED_DATA="${KAISOLA_NATIVE_DERIVED_DATA:-$ROOT/.build/KaisolaNative.noindex}"
VERBOSE=0
RUN_ONLY=0
declare -a SELECTORS=()

usage() {
  /bin/echo "Usage: $0 [--run-only] [--verbose] TestClass[/testMethod] [...]"
  /bin/echo "Example: npm run native:test:focus -- WorkspaceFilesTests"
  /bin/echo ""
  /bin/echo "  --run-only  Re-run already-built tests without compiling"
  /bin/echo "  --verbose   Show the full xcodebuild log"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-only) RUN_ONLY=1 ;;
    --verbose) VERBOSE=1 ;;
    -h|--help) usage; exit 0 ;;
    --*) /bin/echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) SELECTORS+=("$1") ;;
  esac
  shift
done

if [[ "${#SELECTORS[@]}" -eq 0 ]]; then
  /bin/echo "At least one focused test selector is required." >&2
  usage >&2
  exit 2
fi

declare -a TEST_ARGS=()
for selector in "${SELECTORS[@]}"; do
  if [[ "$selector" == KaisolaTests/* ]]; then
    TEST_ARGS+=("-only-testing:$selector")
  else
    TEST_ARGS+=("-only-testing:KaisolaTests/$selector")
  fi
done

declare -a LOG_ARGS=()
[[ "$VERBOSE" -eq 1 ]] || LOG_ARGS+=("-quiet")
ACTION="test"
[[ "$RUN_ONLY" -eq 1 ]] && ACTION="test-without-building"

/bin/mkdir -p "$DERIVED_DATA"
/usr/bin/touch "$DERIVED_DATA/.metadata_never_index"
/bin/echo "Running focused native tests: ${SELECTORS[*]}"
SECONDS=0
/usr/bin/xcodebuild \
  -project "$PROJECT" \
  -scheme Kaisola \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  -destination "platform=macOS,arch=$(uname -m)" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates \
  "${LOG_ARGS[@]}" \
  "${TEST_ARGS[@]}" \
  ONLY_ACTIVE_ARCH=YES \
  ARCHS="$(uname -m)" \
  SWIFT_COMPILATION_MODE=incremental \
  COMPILER_INDEX_STORE_ENABLE=NO \
  BUILD_ACTIVE_RESOURCES_ONLY=YES \
  KAISOLA_PACKAGE_BROKER_HELPER=0 \
  "$ACTION"
/bin/echo "Focused tests finished in ${SECONDS}s."
