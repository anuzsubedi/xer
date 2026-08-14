#!/bin/bash

set -euo pipefail

KEY_PATH="${1:?usage: configure-notarization.sh /path/to/AuthKey_KEYID.p8 KEY_ID [ISSUER_ID]}"
KEY_ID="${2:?usage: configure-notarization.sh /path/to/AuthKey_KEYID.p8 KEY_ID [ISSUER_ID]}"
ISSUER_ID="${3:-}"
PROFILE="${NOTARY_PROFILE:-xer-notary}"

if [[ ! -f "$KEY_PATH" ]]; then
  echo "App Store Connect API key not found: $KEY_PATH" >&2
  exit 1
fi

ARGS=(
  store-credentials "$PROFILE"
  --key "$KEY_PATH"
  --key-id "$KEY_ID"
  --validate
)

if [[ -n "$ISSUER_ID" ]]; then
  ARGS+=(--issuer "$ISSUER_ID")
fi

xcrun notarytool "${ARGS[@]}"
echo "Stored and validated notarytool profile: $PROFILE"

