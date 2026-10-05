#!/usr/bin/env bash
#
# Build a versioned integrity manifest for one or more release artifacts.
#
# The manifest binds every artifact's name, byte size and SHA-256 digest to
# one release version, and is uploaded to the same GitHub release as the
# artifacts it describes. install.sh downloads this fixed-name document,
# validates its schema, and verifies downloaded bytes against it before
# activating anything.
#
# Usage: make-release-manifest.sh <version> <manifest-output> <artifact>...
#
# Example:
#   devbin/make-release-manifest.sh 1.2.3 release-assets/px-manifest.json \
#       release-assets/px.pex

set -eu
set -o pipefail

if [ "$#" -lt 3 ]; then
  echo "usage: $0 <version> <manifest-output> <artifact>..." >&2
  exit 2
fi

VERSION=$1
OUTPUT=$2
shift 2

if ! echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "ERROR: version must be on X.Y.Z form: $VERSION" >&2
  exit 1
fi

ARTIFACTS=()
for artifact in "$@"; do
  if [ ! -f "$artifact" ]; then
    echo "ERROR: artifact is not a file: $artifact" >&2
    exit 1
  fi
  ARTIFACTS+=("$artifact")
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required to build the release manifest" >&2
  exit 1
fi

# Bumped whenever the manifest schema changes in a way install.sh must know
# about.
SCHEMA_VERSION=1

GENERATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

OUTPUT="$OUTPUT" VERSION="$VERSION" SCHEMA_VERSION="$SCHEMA_VERSION" \
  GENERATED_AT="$GENERATED_AT" \
  python3 - "${ARTIFACTS[@]}" <<'PY'
import hashlib
import json
import os
import sys

output = os.environ["OUTPUT"]
version = os.environ["VERSION"]

artifacts = []
seen_names = set()
for path in sys.argv[1:]:
    name = os.path.basename(path)
    if name in seen_names:
        sys.stderr.write(f"ERROR: artifact listed more than once: {name}\n")
        sys.exit(1)
    seen_names.add(name)

    hasher = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            hasher.update(chunk)

    artifacts.append(
        {
            "name": name,
            "size": os.path.getsize(path),
            "sha256": hasher.hexdigest(),
            # Every artifact in one release belongs to the same generation.
            "version": version,
        }
    )

manifest = {
    "schema_version": int(os.environ["SCHEMA_VERSION"]),
    "version": version,
    "generated_at": os.environ["GENERATED_AT"],
    "artifacts": artifacts,
}

with open(output, "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2, sort_keys=False)
    f.write("\n")
PY

echo "Wrote $OUTPUT"
