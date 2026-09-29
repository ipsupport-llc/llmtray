#!/usr/bin/env bash
# Notarizes and staples a DMG (signing it first). Skipped without
# SIGN_IDENTITY. Credentials, one of:
#   NOTARY_PROFILE      a keychain profile (xcrun notarytool store-credentials)
#   NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER_ID   an App Store Connect API key
#   APPLE_ID + APPLE_APP_PASSWORD + APPLE_TEAM_ID        an app-specific password
# Staple before Sparkle signs the DMG: stapling changes the file.
#
# Usage: SIGN_IDENTITY=... NOTARY_PROFILE=llmtray-notary ./scripts/notarize.sh .build/app/LLMTray.dmg
set -euo pipefail

DMG="${1:?usage: notarize.sh path/to/file.dmg}"
if [[ -z "${SIGN_IDENTITY:-}" || "${SIGN_IDENTITY}" == "-" ]]; then
  echo "--- no SIGN_IDENTITY: $DMG not notarized ---"
  exit 0
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  AUTH=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
  AUTH=(--key "$NOTARY_KEY_PATH" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER_ID:?}")
elif [[ -n "${APPLE_ID:-}" ]]; then
  AUTH=(--apple-id "$APPLE_ID" --password "${APPLE_APP_PASSWORD:?}" --team-id "${APPLE_TEAM_ID:?}")
else
  echo "error: SIGN_IDENTITY is set but no notarization credentials (NOTARY_PROFILE, NOTARY_KEY_PATH or APPLE_ID)" >&2
  exit 1
fi

codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
echo "--- submitting $DMG for notarization ---"
OUT="$(xcrun notarytool submit "$DMG" "${AUTH[@]}" --wait --output-format json)"
echo "$OUT"
STATUS="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("status",""))' <<<"$OUT")"
if [[ "$STATUS" != "Accepted" ]]; then
  ID="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("id",""))' <<<"$OUT")"
  [[ -n "$ID" ]] && xcrun notarytool log "$ID" "${AUTH[@]}" || true
  echo "error: notarization $STATUS" >&2
  exit 1
fi
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
echo "--- notarized and stapled $DMG ---"
