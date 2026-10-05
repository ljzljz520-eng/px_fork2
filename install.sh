#!/bin/bash
#
# Download and install the latest px release.
#
# Trust chain:
#   1. A fixed-name release document (px-manifest.json) is fetched from the
#      release tag and validated against a known schema.
#   2. The px.pex artifact is downloaded into a private staging file and its
#      byte size and SHA-256 digest are verified against the manifest.
#   3. The staged artifact is smoke-tested (--version) against the version
#      recorded in the manifest.
#   4. Only then px/ptop/pxtree are activated together with atomic renames,
#      keeping one recoverable old generation and rolling back on trouble.
#
# Environment overrides:
#   PXPREFIX   Install directory (default /usr/local/bin)
#   PX_VERSION "latest" (default) or a pinned X.Y.Z release
#   PX_REPO    GitHub owner/name (default walles/px)

# Give up on any failure
set -e
set -u
set -o pipefail

REPO=${PX_REPO:-walles/px}
PXPREFIX=${PXPREFIX:-/usr/local/bin}
PX_TARGET_VERSION=${PX_VERSION:-latest}

MANIFEST_NAME=px-manifest.json
ARTIFACT_NAME=px.pex
# Only manifests with this schema version are accepted
SCHEMA_VERSION=1

die() {
  echo >&2
  echo "ERROR: $*" >&2
  exit 1
}

# Failure happened before anything in PXPREFIX was touched.
die_unchanged() {
  echo >&2
  echo "ERROR: $*" >&2
  echo >&2
  echo "Your existing px/ptop/pxtree in ${PXPREFIX} were not modified." >&2
  echo "Retry this installer, or pin the last known-good release:" >&2
  echo "  curl -Ls https://github.com/${REPO}/raw/python/install.sh | PX_VERSION=x.y.z bash" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || die "curl is required to install px"
command -v python3 >/dev/null 2>&1 ||
  die "python3 is required to install px (and to run px itself)"

if [ "${PX_TARGET_VERSION}" != "latest" ]; then
  if ! echo "${PX_TARGET_VERSION}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    die "PX_VERSION must be 'latest' or an X.Y.Z version, got: ${PX_TARGET_VERSION}"
  fi
fi

# Private staging area, removed on exit.
WORKDIR=$(mktemp -d 2>/dev/null || mktemp -d -t px-install.XXXXXXXX)
chmod 700 "${WORKDIR}"
cleanup() {
  if [ -n "${WORKDIR:-}" ] && [ -d "${WORKDIR}" ]; then
    rm -rf "${WORKDIR}"
  fi
}
trap cleanup EXIT

# Download "$1" into file "$2". Fails (with diagnostics) on HTTP errors,
# truncation or GitHub API rate limiting.
download_url() {
  local url=$1
  local out=$2

  echo "  ${url}"
  if ! curl -fL --retry 3 --retry-delay 1 --connect-timeout 15 -sS \
    -o "${out}" "${url}"; then
    echo "ERROR: download failed (see curl message above): ${url}" >&2
    if [ -s "${out}" ] && grep -q "API rate limit exceeded" "${out}" 2>/dev/null; then
      cat "${out}" >&2
    fi
    return 1
  fi

  if [ ! -s "${out}" ]; then
    echo "ERROR: download was empty: ${url}" >&2
    return 1
  fi

  # GitHub answers rate limiting with HTTP 200 + an error document sometimes.
  if grep -q "API rate limit exceeded" "${out}" 2>/dev/null &&
    grep -q "documentation_url" "${out}" 2>/dev/null; then
    cat "${out}" >&2
    return 1
  fi
}

# Portable byte count across macOS (BSD stat) and Linux (GNU stat).
file_size() {
  local f=$1
  if stat -f %z "${f}" >/dev/null 2>&1; then
    stat -f %z "${f}"
  elif stat -c %s "${f}" >/dev/null 2>&1; then
    stat -c %s "${f}"
  else
    wc -c <"${f}" | tr -d '[:space:]'
  fi
}

# Portable SHA-256 across Linux (sha256sum), macOS (shasum) and hosts that
# only ship python3. Outputs "<digest>  <file>".
sha256_of() {
  local f=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "${f}"
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "${f}"
  else
    python3 - "${f}" <<'PY'
import hashlib
import sys

h = hashlib.sha256()
with open(sys.argv[1], "rb") as source:
    for chunk in iter(lambda: source.read(1024 * 1024), b""):
        h.update(chunk)
print(h.hexdigest() + "  " + sys.argv[1])
PY
  fi
}

#
# 1. Fetch the fixed release metadata document
#
if [ "${PX_TARGET_VERSION}" = "latest" ]; then
  MANIFEST_URL="https://github.com/${REPO}/releases/latest/download/${MANIFEST_NAME}"
else
  MANIFEST_URL="https://github.com/${REPO}/releases/download/${PX_TARGET_VERSION}/${MANIFEST_NAME}"
fi

echo "Fetching release manifest..."
MANIFEST_FILE="${WORKDIR}/${MANIFEST_NAME}"
download_url "${MANIFEST_URL}" "${MANIFEST_FILE}" ||
  die_unchanged "could not fetch the release manifest from ${MANIFEST_URL}. If this is an older release it may predate signed manifests; pin a newer PX_VERSION."

#
# 2. Validate the manifest schema and extract the px.pex record
#
echo "Validating release manifest..."
FIELDS=$(python3 - "${MANIFEST_FILE}" "${ARTIFACT_NAME}" "${SCHEMA_VERSION}" "${PX_TARGET_VERSION}" <<'PY'
import json
import re
import sys


def fail(message):
    sys.stderr.write("ERROR: invalid release manifest: " + message + "\n")
    sys.exit(1)


path, wanted_name, wanted_schema, pinned_version = sys.argv[1:5]

try:
    with open(path, encoding="utf-8") as source:
        doc = json.load(source)
except Exception as e:  # JSON decode errors are the expected failure here
    fail(f"not valid JSON ({e})")

if not isinstance(doc, dict):
    fail("top-level value must be a JSON object")

schema_version = doc.get("schema_version")
if schema_version != int(wanted_schema):
    fail(
        f"schema_version {schema_version!r} is not supported by this installer "
        f"(expected {wanted_schema}); update install.sh"
    )

version = doc.get("version")
if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
    fail("release 'version' is missing or not on X.Y.Z form")

artifacts = doc.get("artifacts")
if not isinstance(artifacts, list) or not artifacts:
    fail("'artifacts' must be a non-empty list")

record = None
for artifact in artifacts:
    if isinstance(artifact, dict) and artifact.get("name") == wanted_name:
        record = artifact
        break
if record is None:
    fail(f"required artifact {wanted_name!r} is not listed")

size = record.get("size")
if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
    fail("artifact 'size' must be a positive integer")

digest = record.get("sha256")
if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
    fail("artifact 'sha256' must be 64 lowercase hexadecimal characters")

artifact_version = record.get("version")
if artifact_version != version:
    fail(
        f"artifact version {artifact_version!r} does not match release "
        f"version {version!r}"
    )

if pinned_version != "latest" and pinned_version != version:
    fail(f"manifest version {version} does not match pinned PX_VERSION={pinned_version}")

# Exactly four lines, order is part of the contract with the shell below.
print(version)
print(wanted_name)
print(size)
print(digest)
PY
) || die_unchanged "manifest validation failed; refusing to install"

{
  IFS= read -r MANIFEST_VERSION
  IFS= read -r MANIFEST_ARTIFACT
  IFS= read -r MANIFEST_SIZE
  IFS= read -r MANIFEST_SHA256
} <<<"${FIELDS}"

# Defense in depth: never trust program output without re-checking it here.
echo "${MANIFEST_VERSION}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' ||
  die_unchanged "manifest reported an invalid version: ${MANIFEST_VERSION:-<empty>}"
[ "${MANIFEST_ARTIFACT}" = "${ARTIFACT_NAME}" ] ||
  die_unchanged "manifest returned the wrong artifact: ${MANIFEST_ARTIFACT:-<empty>}"
echo "${MANIFEST_SIZE}" | grep -Eq '^[0-9]+$' ||
  die_unchanged "manifest reported an invalid size"
echo "${MANIFEST_SHA256}" | grep -Eq '^[0-9a-f]{64}$' ||
  die_unchanged "manifest reported an invalid SHA-256 digest"

# The manifest is authoritative for the version, so derive the artifact URL
# from it instead of trusting any URL field in the document.
ARTIFACT_URL="https://github.com/${REPO}/releases/download/${MANIFEST_VERSION}/${ARTIFACT_NAME}"

#
# 3. Download the artifact into a private (0600) staging file
#
echo "Downloading ${ARTIFACT_NAME} ${MANIFEST_VERSION}..."
ARTIFACT_FILE="${WORKDIR}/${ARTIFACT_NAME}"
PRIVATE_FILE=$(mktemp "${WORKDIR}/artifact.XXXXXXXX")
download_url "${ARTIFACT_URL}" "${PRIVATE_FILE}" ||
  die_unchanged "could not download ${ARTIFACT_URL}"

#
# 4. Verify size, digest and artifact type before making anything executable
#
echo "Verifying size and SHA-256..."
ACTUAL_SIZE=$(file_size "${PRIVATE_FILE}")
if [ "${ACTUAL_SIZE}" != "${MANIFEST_SIZE}" ]; then
  die_unchanged "size mismatch for ${ARTIFACT_NAME}: manifest says ${MANIFEST_SIZE} bytes, downloaded ${ACTUAL_SIZE} bytes"
fi

ACTUAL_SHA256=$(sha256_of "${PRIVATE_FILE}" | awk '{print $1}')
if [ "${ACTUAL_SHA256}" != "${MANIFEST_SHA256}" ]; then
  die_unchanged "SHA-256 mismatch for ${ARTIFACT_NAME}:
  expected ${MANIFEST_SHA256}
  actual   ${ACTUAL_SHA256}"
fi

FIRST_LINE=$(head -n1 "${PRIVATE_FILE}")
case "${FIRST_LINE}" in
  \#!*python3*) ;;
  *)
    die_unchanged "artifact is not a python3 executable (first line: ${FIRST_LINE:-<empty>})"
    ;;
esac

# Digest verified: now it is safe to make the staged file executable.
chmod a+x "${PRIVATE_FILE}"

#
# 5. Smoke test the staged binary against the manifest version
#
echo "Smoke testing the staged artifact (--version)..."
if ! SMOKE_OUTPUT=$("${PRIVATE_FILE}" --version 2>"${WORKDIR}/smoke.err"); then
  echo "--- artifact error output ---" >&2
  cat "${WORKDIR}/smoke.err" >&2
  die_unchanged "staged artifact failed to run: ${ARTIFACT_NAME} --version"
fi
SMOKE_VERSION=$(echo "${SMOKE_OUTPUT}" | head -n1 | tr -d '\r')
if [ "${SMOKE_VERSION}" != "${MANIFEST_VERSION}" ]; then
  die_unchanged "artifact version mismatch: manifest says ${MANIFEST_VERSION}, ${ARTIFACT_NAME} --version reports '${SMOKE_VERSION}'"
fi

cp "${PRIVATE_FILE}" "${ARTIFACT_FILE}"
chmod a+x "${ARTIFACT_FILE}"

#
# 6. Atomically activate the whole px/ptop/pxtree generation
#
# The activation runs in one privileged shell so that either all three names
# are replaced (via rename(2) inside PXPREFIX) or the old generation is
# restored. Staging happens on the same filesystem as PXPREFIX to guarantee
# atomic renames and to fail early on permission or space problems before the
# installed commands are touched.
ACTIVATE_SCRIPT=$(cat <<'ACTIVATE_EOF'
set -e
set -u
set -o pipefail

PREFIX=$1
SRC=$2
VERSION=$3

NAMES=(px ptop pxtree)
STAGE=$(mktemp -d "${PREFIX}/.px-stage.XXXXXX")
BACKUP="${PREFIX}/.px-backup.$$"
PREVIOUS="${PREFIX}/.px-previous"

rollback() {
  # Never re-enter this handler, and never let failures inside it recurse.
  trap - ERR
  set +e

  if [ -d "${BACKUP}" ]; then
    echo "ERROR: activation failed; restoring the previous generation..." >&2
    for name in "${NAMES[@]}"; do
      if [ -e "${BACKUP}/${name}" ] || [ -L "${BACKUP}/${name}" ]; then
        # Old entry exists: put it back (overrides any half-activated one)
        mv -f "${BACKUP}/${name}" "${PREFIX}/${name}" 2>/dev/null
      elif [ -e "${STAGE}/.activated-${name}" ] || [ -L "${STAGE}/.activated-${name}" ]; then
        # Fresh-install entry from the failed generation: remove it
        rm -f "${PREFIX}/${name}" 2>/dev/null
      fi
      # Otherwise this name was never touched; leave it alone.
    done
    rmdir "${BACKUP}" 2>/dev/null
    echo "ERROR: rollback finished; px/ptop/pxtree should be the old version." >&2
  else
    echo "ERROR: activation failed before the existing install was touched." >&2
    echo "ERROR: px/ptop/pxtree in ${PREFIX} are unchanged." >&2
  fi
  rm -rf "${STAGE}" 2>/dev/null

  # An ERR trap returning successfully would let the script continue; we must
  # terminate the failed activation explicitly.
  exit 1
}
trap rollback ERR

# 6.1 Stage the complete new generation next to the targets (same filesystem)
install -m 0755 "${SRC}" "${STAGE}/px"
ln -s px "${STAGE}/ptop"
ln -s px "${STAGE}/pxtree"

# 6.2 Preflight staged generation before touching any installed command
[ -x "${STAGE}/px" ]
[ "$(readlink "${STAGE}/ptop")" = "px" ]
[ "$(readlink "${STAGE}/pxtree")" = "px" ]
STAGED_VERSION=$("${STAGE}/px" --version 2>/dev/null | head -n1)
[ "${STAGED_VERSION}" = "${VERSION}" ]

# 6.3 Move old generation aside as one cohort
HAD_OLD=0
mkdir -m 0700 "${BACKUP}"
for name in "${NAMES[@]}"; do
  if [ -e "${PREFIX}/${name}" ] || [ -L "${PREFIX}/${name}" ]; then
    mv "${PREFIX}/${name}" "${BACKUP}/${name}"
    HAD_OLD=1
  fi
done

# 6.4 Atomic activation. ptop/pxtree are relative symlinks to px, so once px
#     is renamed into place all three commands serve the same generation;
#     there is no observable old/new generation mix.
for name in "${NAMES[@]}"; do
  mv "${STAGE}/${name}" "${PREFIX}/${name}"
  touch "${STAGE}/.activated-${name}"
done

# 6.5 Verify activated generation at its final location
[ -x "${PREFIX}/px" ]
[ "$(readlink "${PREFIX}/ptop")" = "px" ]
[ "$(readlink "${PREFIX}/pxtree")" = "px" ]
INSTALLED_VERSION=$("${PREFIX}/px" --version 2>/dev/null | head -n1)
[ "${INSTALLED_VERSION}" = "${VERSION}" ]

trap - ERR

# 6.6 Keep exactly one recoverable previous generation. This must never undo
#     the already-verified activation.
if [ "${HAD_OLD}" -eq 1 ]; then
  if rm -rf "${PREVIOUS}" 2>/dev/null && mv "${BACKUP}" "${PREVIOUS}" 2>/dev/null; then
    echo "Previous generation preserved at ${PREVIOUS}"
    echo "Restore it with:"
    echo "  sudo bash -c 'for n in px ptop pxtree; do mv -f \"${PREVIOUS}/\$n\" \"${PREFIX}/\$n\"; done'"
  else
    echo "WARNING: could not rotate backup; old generation kept at ${BACKUP}" >&2
  fi
else
  rmdir "${BACKUP}" 2>/dev/null || true
fi
rm -rf "${STAGE}" 2>/dev/null || true

echo "Activated px/ptop/pxtree ${VERSION} in ${PREFIX}"
ACTIVATE_EOF
)

if [ ! -d "${PXPREFIX}" ]; then
  die_unchanged "install directory does not exist: ${PXPREFIX}"
fi

echo
echo "Installing px ${MANIFEST_VERSION} into ${PXPREFIX}..."
if [ -w "${PXPREFIX}" ] && [ ! -L "${PXPREFIX}" ]; then
  if ! bash -c "${ACTIVATE_SCRIPT}" bash "${PXPREFIX}" "${ARTIFACT_FILE}" "${MANIFEST_VERSION}"; then
    die "activation failed in ${PXPREFIX}. Check the messages above; the old generation should have been restored (look for ${PXPREFIX}/.px-previous or ${PXPREFIX}/.px-backup.*)."
  fi
else
  echo "Need administrator rights to write to ${PXPREFIX}."
  sudo -v ||
    die_unchanged "administrator rights (sudo) are required to write to ${PXPREFIX}"
  if ! sudo bash -c "${ACTIVATE_SCRIPT}" bash "${PXPREFIX}" "${ARTIFACT_FILE}" "${MANIFEST_VERSION}"; then
    die "activation failed in ${PXPREFIX}. Check the messages above; the old generation should have been restored (look for ${PXPREFIX}/.px-previous or ${PXPREFIX}/.px-backup.*)."
  fi
fi

echo
echo "Installation done. Verify (expect ${MANIFEST_VERSION}):"
echo "  px --version"
echo
echo "Then run one or all of:"
echo "  ptop"
echo "  pxtree"
echo "  px"
