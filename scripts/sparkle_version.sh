#!/usr/bin/env bash
# Maps a release version to the one Sparkle compares (CFBundleVersion /
# <sparkle:version>). Tags are vX.Y.Z or vX.Y.Z-beta.N; Sparkle's
# SUStandardVersionComparator treats "0.6.8-beta.1" as EQUAL to "0.6.8"
# and to every other "-beta.N" (checked against the bundled Sparkle), so a
# beta would never update to the next beta or to the release. "0.6.8b1"
# orders correctly: 0.6.7 < 0.6.8b1 < 0.6.8b2 < 0.6.8b10 < 0.6.8 < 0.6.9b1.
# Any other suffix is rejected rather than risk that equality trap.
#
# Usage: sparkle_version.sh 0.6.8-beta.1   -> 0.6.8b1
set -euo pipefail
v="${1:?version required}"
if [[ "$v" =~ ^([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  echo "$v"
elif [[ "$v" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-beta\.([0-9]+)$ ]]; then
  echo "${BASH_REMATCH[1]}b${BASH_REMATCH[2]}"
elif [[ "$v" == "0.0.0-dev" ]]; then
  echo "0.0.0"   # plain local builds
else
  echo "error: unsupported version '$v' (expected X.Y.Z or X.Y.Z-beta.N)" >&2
  exit 1
fi
