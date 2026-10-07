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

# An upload can hang with no submission created (2026-10-07: 20 min on the
# 316 MB DMG, nothing at Apple); notarytool's --timeout covers only the
# wait. Each attempt is stopped after NOTARY_ATTEMPT_MINUTES, then retried.
ATTEMPT_SECONDS=$(( ${NOTARY_ATTEMPT_MINUTES:-30} * 60 ))
ATTEMPTS="${NOTARY_ATTEMPTS:-3}"
OUT_FILE="$(mktemp)"
trap 'rm -f "$OUT_FILE"' EXIT
submit_once() {
  # exec: no shell of ours in between, so no EXIT trap of ours runs (and
  # deletes OUT_FILE) when the attempt is stopped.
  { trap - EXIT; exec xcrun notarytool submit "$DMG" "${AUTH[@]}" --wait --output-format json; } > "$OUT_FILE" &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= ATTEMPT_SECONDS )); then
      kill "$pid" 2>/dev/null || true
      # Up to 10 s to go, then killed outright: the wait below can't hang.
      for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      echo "--- notarization attempt stopped after $(( ATTEMPT_SECONDS / 60 )) min ---"
      return 124
    fi
    sleep 5
    waited=$(( waited + 5 ))
  done
  wait "$pid"
}
OUT=""
for (( attempt = 1; attempt <= ATTEMPTS; attempt++ )); do
  echo "--- submitting $DMG for notarization (attempt $attempt of $ATTEMPTS) ---"
  submit_once || true
  # A verdict (Accepted, Invalid ...) ends it, whatever the exit code and
  # even if it came just as the attempt was stopped; no status (a network
  # error, a stopped upload) is tried again.
  OUT="$(cat "$OUT_FILE" 2>/dev/null || true)"
  STATUS="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read() or "{}").get("status",""))' <<<"$OUT" 2>/dev/null || true)"
  [[ -n "$STATUS" ]] && break
  OUT=""
done
[[ -n "$OUT" ]] || { echo "error: notarization of $DMG didn't finish in $ATTEMPTS attempts" >&2; exit 1; }
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
