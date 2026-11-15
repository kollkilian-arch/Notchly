#!/usr/bin/env bash
# Creates a local, self-signed code-signing identity ("Notchly Local Signing") in your login keychain.
#
# Why: an ad-hoc signature changes with every build, so macOS forgets the Accessibility and
# Keychain approvals each time. Signing with a fixed certificate keeps the app's identity stable.
# The certificate is only for this Mac; it does not change any trust settings.
set -euo pipefail

NAME="${SIGN_IDENTITY:-Notchly Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "Signing identity \"$NAME\" already exists. Nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT      # private key material never outlives this script
umask 077
cd "$WORK"

cat > cert.cnf <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf 2>/dev/null

PASS="$(openssl rand -hex 12)"
# Legacy algorithms: macOS `security import` cannot read OpenSSL 3's default PKCS#12 encryption.
openssl pkcs12 -export -inkey key.pem -in cert.pem -out cert.p12 -name "$NAME" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -passout "pass:$PASS"

# -T lets codesign use the key without asking every time.
security import cert.p12 -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign

echo
echo "Created signing identity \"$NAME\". Build with ./build.sh."
echo "(If macOS asks whether codesign may use the key, choose \"Always Allow\".)"
