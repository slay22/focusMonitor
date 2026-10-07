#!/bin/sh
# One-time: creates a self-signed code-signing identity in your login keychain. build.sh then signs with it,
# so the app keeps the same signature across rebuilds and macOS keeps its Accessibility/Camera grants.
# Remove later with: security delete-identity -c "focusMonitor Self-Signed"
set -e
NAME="focusMonitor Self-Signed"
security find-identity -p codesigning | grep -q "$NAME" && { echo "Already exists: $NAME"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
  -keyout "$T/key.pem" -out "$T/cert.pem" \
  -addext "basicConstraints=critical,CA:false" -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -name "$NAME" -passout pass:tmp -out "$T/id.p12"
security import "$T/id.p12" -k ~/Library/Keychains/login.keychain-db -P tmp -T /usr/bin/codesign
echo "Created: $NAME"
