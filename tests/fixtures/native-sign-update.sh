#!/bin/sh
set -eu

if [ -n "${EXPECTED_ED_KEY_FILE:-}" ]; then
  [ "${1:-}" = "--ed-key-file" ] || { echo "missing --ed-key-file" >&2; exit 7; }
  [ "${2:-}" = "$EXPECTED_ED_KEY_FILE" ] || { echo "unexpected Ed25519 key file" >&2; exit 7; }
fi

if [ "${1:-}" = "--ed-key-file" ]; then
  [ "$#" -ge 3 ] || { echo "--ed-key-file requires a value" >&2; exit 7; }
  shift 2
fi

[ "$#" -eq 1 ] || { echo "expected one archive path" >&2; exit 7; }

case "${NATIVE_SIGN_UPDATE_STUB_MODE:-ok}" in
  fail)
    echo "fixture sign_update failure" >&2
    exit 9
    ;;
  missing)
    echo "signature intentionally omitted"
    exit 0
    ;;
  ok)
    length=$(/usr/bin/wc -c < "$1" | /usr/bin/tr -d '[:space:]')
    printf '%s\n' "sparkle:edSignature=\"paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpQ==\" length=\"$length\""
    ;;
  *)
    echo "unknown fixture mode" >&2
    exit 7
    ;;
esac
