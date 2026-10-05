#!/bin/bash
#
# Tests for install.sh, fully offline: curl is faked and serves local
# fixtures. Covers the happy path, the verified upgrade/recovery path and
# all the ways manifest/artifact validation must refuse to install.

set -e
set -u
set -o pipefail

WORKDIR=$(mktemp -d 2>/dev/null || mktemp -d -t px-installtest.XXXXXXXX)
function installer-cleanup {
  rm -rf "${WORKDIR}"
}
trap installer-cleanup EXIT

RATELIMIT_JSON=tests/api.github.com_releases-ratelimit.json

#
# Create fake python3 executable "pex" fixtures. The shebang must identify
# them as python3 (install.sh checks), so they really are python3 scripts.
#
PEX_123_DIR="${WORKDIR}/v1.2.3"
PEX_124_DIR="${WORKDIR}/v1.2.4"
PEX_BAD_DIR="${WORKDIR}/v-bad"
mkdir "${PEX_123_DIR}" "${PEX_124_DIR}" "${PEX_BAD_DIR}"

cat >"${PEX_123_DIR}/px.pex" <<'EOF'
#!/usr/bin/env python3
import sys
if sys.argv[1:] == ["--version"]:
    print("1.2.3")
EOF

cat >"${PEX_124_DIR}/px.pex" <<'EOF'
#!/usr/bin/env python3
import sys
if sys.argv[1:] == ["--version"]:
    print("1.2.4")
EOF

# Manifest claims 1.2.3, but this binary reports something else
cat >"${PEX_BAD_DIR}/px.pex" <<'EOF'
#!/usr/bin/env python3
import sys
if sys.argv[1:] == ["--version"]:
    print("1.2.2")
EOF
chmod a+x "${PEX_123_DIR}/px.pex" "${PEX_124_DIR}/px.pex" "${PEX_BAD_DIR}/px.pex"

#
# Generate manifests with the same script the release workflow uses. Note
# how each fixture is presented under its real release-asset name, px.pex.
#
bash ./devbin/make-release-manifest.sh 1.2.3 \
  "${WORKDIR}/manifest-1.2.3.json" "${PEX_123_DIR}/px.pex" >/dev/null
bash ./devbin/make-release-manifest.sh 1.2.4 \
  "${WORKDIR}/manifest-1.2.4.json" "${PEX_124_DIR}/px.pex" >/dev/null
bash ./devbin/make-release-manifest.sh 1.2.3 \
  "${WORKDIR}/manifest-bad-version.json" "${PEX_BAD_DIR}/px.pex" >/dev/null
echo '{ this is not valid JSON' >"${WORKDIR}/manifest-broken.json"

#
# Create a fake no-op sudo (used only if PXPREFIX is not writable)...
#
SUDO="${WORKDIR}/sudo"
echo '#!/bin/sh' >"${SUDO}"
echo '"$@"' >>"${SUDO}"
chmod a+x "${SUDO}"

#
# ... and a fake curl. It serves either the manifest or the pex fixture
# named by the MOCK_* environment variables, based on the requested URL.
#
CURL="${WORKDIR}/curl"
cat >"${CURL}" <<'CURL_EOF'
#!/bin/sh
set -u
out=""
url=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    out=$2
  fi
  url=$1
  shift
done

if [ "${MOCK_MODE}" = "ratelimit" ]; then
  cat "${RATELIMIT_JSON}" >"${out}"
  exit 0
fi

case "${url}" in
  *px-manifest.json)
    cat "${MOCK_MANIFEST}" >"${out}"
    ;;
  *px.pex)
    if [ "${MOCK_MODE}" = "corrupt" ]; then
      # Doubled bytes: wrong size and wrong digest
      cat "${MOCK_PEX}" "${MOCK_PEX}" >"${out}"
    else
      cat "${MOCK_PEX}" >"${out}"
    fi
    ;;
  *)
    echo "fake curl got unexpected URL: ${url}" >&2
    exit 1
    ;;
esac
CURL_EOF
chmod a+x "${CURL}"

# Put both fakes first in the PATH
export PATH=${WORKDIR}:$PATH
export RATELIMIT_JSON

PREFIX_A="${WORKDIR}/prefix-a"
PREFIX_B="${WORKDIR}/prefix-b"
PREFIX_C="${WORKDIR}/prefix-c"
PREFIX_D="${WORKDIR}/prefix-d"
PREFIX_E="${WORKDIR}/prefix-e"
PREFIX_F="${WORKDIR}/prefix-f"
mkdir "${PREFIX_A}" "${PREFIX_B}" "${PREFIX_C}" "${PREFIX_D}" "${PREFIX_E}" "${PREFIX_F}"

run_installer() {
  # $1=prefix $2=manifest $3=pex $4=mode
  MOCK_MODE="$4" MOCK_MANIFEST="$2" MOCK_PEX="$3" \
    PXPREFIX="$1" bash ./install.sh
}

#
# Happy-path install
#
cat <<EOF
#
#  Testing happy-path install...
#
EOF
run_installer "${PREFIX_A}" "${WORKDIR}/manifest-1.2.3.json" \
  "${PEX_123_DIR}/px.pex" happy >"${WORKDIR}/install.out"
test -x "${PREFIX_A}/px"
test -L "${PREFIX_A}/ptop"
test -L "${PREFIX_A}/pxtree"
[ "$(readlink "${PREFIX_A}/ptop")" = "px" ]
[ "$(readlink "${PREFIX_A}/pxtree")" = "px" ]
[ "$("${PREFIX_A}/px" --version)" = "1.2.3" ]

#
# Verified upgrade: the new generation activates and the old one is kept
# recoverable.
#
cat <<EOF
#
#  Testing verified upgrade and previous-generation recovery...
#
EOF
run_installer "${PREFIX_A}" "${WORKDIR}/manifest-1.2.4.json" \
  "${PEX_124_DIR}/px.pex" happy >"${WORKDIR}/upgrade.out"
[ "$("${PREFIX_A}/px" --version)" = "1.2.4" ]
test -L "${PREFIX_A}/ptop"
test -L "${PREFIX_A}/pxtree"
grep -q "Previous generation preserved" "${WORKDIR}/upgrade.out"

# The whole old cohort, including its symlinks, was preserved
test -e "${PREFIX_A}/.px-previous/px"
test -L "${PREFIX_A}/.px-previous/ptop"
test -L "${PREFIX_A}/.px-previous/pxtree"
[ "$("${PREFIX_A}/.px-previous/px" --version)" = "1.2.3" ]

# Recover the old generation using the documented restore operation
for n in px ptop pxtree; do
  mv -f "${PREFIX_A}/.px-previous/$n" "${PREFIX_A}/$n"
done
[ "$("${PREFIX_A}/px" --version)" = "1.2.3" ]
[ "$(readlink "${PREFIX_A}/ptop")" = "px" ]
[ "$(readlink "${PREFIX_A}/pxtree")" = "px" ]

#
# Rate-limited by GitHub: failure, clear error, and nothing installed
#
cat <<EOF
#
#  Testing rate-limited by GitHub install...
#
EOF
if run_installer "${PREFIX_B}" "${WORKDIR}/manifest-1.2.3.json" \
  "${PEX_123_DIR}/px.pex" ratelimit 2>"${WORKDIR}/ratelimit.err"; then
  echo "ERROR: rate-limited install should have failed" >&2
  exit 1
fi
grep -q "API rate limit exceeded" "${WORKDIR}/ratelimit.err"
for n in px ptop pxtree; do
  test ! -e "${PREFIX_B}/$n"
done

#
# Corrupted artifact (size and SHA-256 mismatch): nothing must be installed
#
cat <<EOF
#
#  Testing corrupted-artifact refusal...
#
EOF
if run_installer "${PREFIX_C}" "${WORKDIR}/manifest-1.2.3.json" \
  "${PEX_123_DIR}/px.pex" corrupt 2>"${WORKDIR}/corrupt.err"; then
  echo "ERROR: corrupted install should have failed" >&2
  exit 1
fi
grep -qi "mismatch" "${WORKDIR}/corrupt.err"
grep -q "were not modified" "${WORKDIR}/corrupt.err"
for n in px ptop pxtree; do
  test ! -e "${PREFIX_C}/$n"
done

#
# Artifact whose --version does not match the manifest: refused
#
cat <<EOF
#
#  Testing artifact/report version mismatch refusal...
#
EOF
if run_installer "${PREFIX_D}" "${WORKDIR}/manifest-bad-version.json" \
  "${PEX_BAD_DIR}/px.pex" happy 2>"${WORKDIR}/wrongversion.err"; then
  echo "ERROR: wrong-version install should have failed" >&2
  exit 1
fi
grep -q "artifact version mismatch" "${WORKDIR}/wrongversion.err"
for n in px ptop pxtree; do
  test ! -e "${PREFIX_D}/$n"
done

#
# Manifest that is not valid JSON / fails the schema: refused
#
cat <<EOF
#
#  Testing malformed-manifest refusal...
#
EOF
if run_installer "${PREFIX_E}" "${WORKDIR}/manifest-broken.json" \
  "${PEX_123_DIR}/px.pex" happy 2>"${WORKDIR}/broken.err"; then
  echo "ERROR: broken-manifest install should have failed" >&2
  exit 1
fi
grep -q "not valid JSON" "${WORKDIR}/broken.err"
for n in px ptop pxtree; do
  test ! -e "${PREFIX_E}/$n"
done

#
# Pinned release install: version-specific manifest URL and success
#
cat <<EOF
#
#  Testing pinned-release install...
#
EOF
MOCK_MODE=happy MOCK_MANIFEST="${WORKDIR}/manifest-1.2.3.json" \
  MOCK_PEX="${PEX_123_DIR}/px.pex" PXPREFIX="${PREFIX_F}" \
  PX_VERSION=1.2.3 bash ./install.sh >"${WORKDIR}/pinned.out"
grep -q "releases/download/1.2.3/px-manifest.json" "${WORKDIR}/pinned.out"
[ "$("${PREFIX_F}/px" --version)" = "1.2.3" ]

#
# Pinned version disagreeing with the manifest: refused, nothing installed
#
cat <<EOF
#
#  Testing pinned-version mismatch refusal...
#
EOF
PREFIX_G="${WORKDIR}/prefix-g"
mkdir "${PREFIX_G}"
if MOCK_MODE=happy MOCK_MANIFEST="${WORKDIR}/manifest-1.2.3.json" \
  MOCK_PEX="${PEX_123_DIR}/px.pex" PXPREFIX="${PREFIX_G}" \
  PX_VERSION=1.2.4 bash ./install.sh 2>"${WORKDIR}/pinmismatch.err"; then
  echo "ERROR: pin mismatch install should have failed" >&2
  exit 1
fi
grep -q "does not match pinned PX_VERSION=1.2.4" "${WORKDIR}/pinmismatch.err"
for n in px ptop pxtree; do
  test ! -e "${PREFIX_G}/$n"
done

#
# Nonexistent install directory: refused before any privileged operation
#
cat <<EOF
#
#  Testing missing install directory...
#
EOF
if MOCK_MODE=happy MOCK_MANIFEST="${WORKDIR}/manifest-1.2.3.json" \
  MOCK_PEX="${PEX_123_DIR}/px.pex" PXPREFIX="${WORKDIR}/no-such-dir" \
  bash ./install.sh 2>"${WORKDIR}/nodir.err"; then
  echo "ERROR: missing-directory install should have failed" >&2
  exit 1
fi
grep -q "install directory does not exist" "${WORKDIR}/nodir.err"

#
# Unwritable install directory with sudo unavailable: refused and untouched.
# Skipped when running as root, where write checks always succeed.
#
if [ "$(id -u)" -ne 0 ]; then
  cat <<EOF
#
#  Testing unwritable-prefix refusal (sudo unavailable)...
#
EOF
  NOSUDO="${WORKDIR}/nosudo"
  mkdir "${NOSUDO}"
  cat >"${NOSUDO}/sudo" <<'EOF'
#!/bin/sh
echo "sudo: not allowed in this test" >&2
exit 1
EOF
  chmod a+x "${NOSUDO}/sudo"

  PREFIX_H="${WORKDIR}/prefix-h"
  mkdir "${PREFIX_H}"
  chmod 555 "${PREFIX_H}"
  if env PATH="${NOSUDO}:${PATH}" MOCK_MODE=happy \
    MOCK_MANIFEST="${WORKDIR}/manifest-1.2.3.json" \
    MOCK_PEX="${PEX_123_DIR}/px.pex" PXPREFIX="${PREFIX_H}" \
    bash ./install.sh 2>"${WORKDIR}/readonly.err"; then
    echo "ERROR: read-only prefix install should have failed" >&2
    exit 1
  fi
  grep -q "administrator rights" "${WORKDIR}/readonly.err"
  for n in px ptop pxtree; do
    test ! -e "${PREFIX_H}/$n"
  done
  chmod 755 "${PREFIX_H}"
fi

echo
echo "All install.sh tests passed."
