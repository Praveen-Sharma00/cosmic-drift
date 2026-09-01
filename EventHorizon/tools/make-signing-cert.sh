#!/bin/bash
# Creates a self-signed code signing certificate in the login keychain.
#
# Why: build.sh otherwise signs ad hoc, which gives the app a brand new code
# identity on every build. macOS keys the Screen Recording grant to that
# identity, so every rebuild silently revoked it. Signing with a stable
# certificate makes the app's designated requirement constant, and the grant
# survives rebuilds.
#
# Run once. Expect two prompts from macOS: one to modify trust settings, and
# one the first time codesign uses the key (choose "Always Allow").
set -euo pipefail

NAME="Event Horizon Local Signing"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "${NAME}"; then
  echo "identity already present: ${NAME}"
  security find-identity -v -p codesigning | grep "${NAME}"
  exit 0
fi

DIR="$(mktemp -d)"
trap 'rm -rf "${DIR}"' EXIT

# A config file rather than -addext, because macOS ships LibreSSL.
cat > "${DIR}/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[ dn ]
CN = ${NAME}

[ v3 ]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "${DIR}/key.pem" -out "${DIR}/cert.pem" \
  -config "${DIR}/openssl.cnf" 2>/dev/null

# The legacy PBE/MAC algorithms are required: macOS's Security framework
# rejects OpenSSL 3's modern defaults with "MAC verification failed".
openssl pkcs12 -export -out "${DIR}/id.p12" \
  -inkey "${DIR}/key.pem" -in "${DIR}/cert.pem" \
  -name "${NAME}" -passout pass:eventhorizon \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

# -T lets codesign use the key without a prompt per invocation (subject to the
# partition list, which may still ask once).
security import "${DIR}/id.p12" -k "${KEYCHAIN}" -P eventhorizon \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "imported certificate; macOS will now ask to modify trust settings"
security add-trusted-cert -r trustRoot -p codeSign -k "${KEYCHAIN}" "${DIR}/cert.pem"

echo
security find-identity -v -p codesigning | grep "${NAME}" || {
  echo "certificate imported but not usable for signing yet" >&2
  exit 1
}
echo "done - rebuild with ./build.sh"
