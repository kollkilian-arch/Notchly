#!/usr/bin/env bash
# Creates a certificate for signing GitHub releases and prepares the two repository secrets
# the release workflow needs. Run it once.
#
# This is a different certificate from the one ./setup-signing.sh puts in your keychain: it exists only
# for CI, and it is NOT added to your keychain. The files are written outside the repository.
#
#   ~/Notchly-release-signing/RELEASE_CERT_P12_BASE64.txt   -> secret  RELEASE_CERT_P12_BASE64
#   ~/Notchly-release-signing/RELEASE_CERT_PASSWORD.txt     -> secret  RELEASE_CERT_PASSWORD
#
# Add them at: GitHub repo → Settings → Secrets and variables → Actions → New repository secret.
# Then delete the folder. Keep the certificate stable: if it ever changes, recipients of your
# releases will be asked for their permissions again once.
set -euo pipefail

NAME="Notchly Release Signing"
OUT="${1:-$HOME/Notchly-release-signing}"

if [ -e "$OUT" ]; then
    echo "error: $OUT already exists. Move or delete it first (or pass another folder)." >&2
    exit 1
fi

umask 077
mkdir -p "$OUT"
chmod 700 "$OUT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT      # the private key itself never outlives this script
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

PASS="$(openssl rand -hex 16)"
# Legacy algorithms: macOS `security import` cannot read OpenSSL 3's default PKCS#12 encryption.
openssl pkcs12 -export -inkey key.pem -in cert.pem -out release.p12 -name "$NAME" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -passout "pass:$PASS"

base64 < release.p12 | tr -d '\n' > "$OUT/RELEASE_CERT_P12_BASE64.txt"
printf '%s' "$PASS" > "$OUT/RELEASE_CERT_PASSWORD.txt"
FINGERPRINT="$(openssl x509 -in cert.pem -noout -fingerprint -sha1 | sed 's/.*=//')"

cat <<EOF

Created the release certificate "$NAME"
  SHA-1 fingerprint: $FINGERPRINT   (public; you can compare it later)
  Files in: $OUT

Next, in GitHub (repo → Settings → Secrets and variables → Actions → New repository secret):

  1. Name: RELEASE_CERT_P12_BASE64     value: the contents of RELEASE_CERT_P12_BASE64.txt
       copy it with:  pbcopy < "$OUT/RELEASE_CERT_P12_BASE64.txt"
  2. Name: RELEASE_CERT_PASSWORD       value: the contents of RELEASE_CERT_PASSWORD.txt
       copy it with:  pbcopy < "$OUT/RELEASE_CERT_PASSWORD.txt"

Then delete the folder:  rm -rf "$OUT"
EOF
