#!/usr/bin/env bash
set -euo pipefail

version=1.2.896.0
fingerprint=7959637124CE093AD501D47A2C4D4AFF6F6757EE
package_url="https://s3.amazonaws.com/session-manager-downloads/plugin/$version/ubuntu_64bit/session-manager-plugin.deb"
workspace=$(mktemp -d)
trap 'rm -rf "$workspace"' EXIT
export GNUPGHOME="$workspace/gnupg"
mkdir -m 700 "$GNUPGHOME"

# AWS publishes this Linux signing key in its Session Manager plugin verification guide.
cat > "$workspace/signing-key.asc" <<'KEY'
-----BEGIN PGP PUBLIC KEY BLOCK-----

mFIEZ5ERQxMIKoZIzj0DAQcCAwQjuZy+IjFoYg57sLTGhF3aZLBaGpzB+gY6j7Ix
P7NqbpXyjVj8a+dy79gSd64OEaMxUb7vw/jug+CfRXwVGRMNtIBBV1MgU1NNIFNl
c3Npb24gTWFuYWdlciA8c2Vzc2lvbi1tYW5hZ2VyLXBsdWdpbi1zaWduZXJAYW1h
em9uLmNvbT4gKEFXUyBTeXN0ZW1zIE1hbmFnZXIgU2Vzc2lvbiBNYW5hZ2VyIFBs
dWdpbiBMaW51eCBTaWduZXIgS2V5KYkBAAQQEwgAqAUCZ5ERQ4EcQVdTIFNTTSBT
ZXNzaW9uIE1hbmFnZXIgPHNlc3Npb24tbWFuYWdlci1wbHVnaW4tc2lnbmVyQGFt
YXpvbi5jb20+IChBV1MgU3lzdGVtcyBNYW5hZ2VyIFNlc3Npb24gTWFuYWdlciBQ
bHVnaW4gTGludXggU2lnbmVyIEtleSkWIQR5WWNxJM4JOtUB1HosTUr/b2dX7gIe
AwIbAwIVCAAKCRAsTUr/b2dX7rO1AQCa1kig3lQ78W/QHGU76uHx3XAyv0tfpE9U
oQBCIwFLSgEA3PDHt3lZ+s6m9JLGJsy+Cp5ZFzpiF6RgluR/2gA861M=
=2DQm
-----END PGP PUBLIC KEY BLOCK-----
KEY

curl --fail --silent --show-error --location --retry 3 --max-time 60 "$package_url" -o "$workspace/plugin.deb"
curl --fail --silent --show-error --location --retry 3 --max-time 60 "$package_url.sig" -o "$workspace/plugin.deb.sig"
gpg --batch --import "$workspace/signing-key.asc"
gpg --batch --export "$fingerprint" > "$workspace/signing-key.gpg"
gpgv --keyring "$workspace/signing-key.gpg" "$workspace/plugin.deb.sig" "$workspace/plugin.deb"
sudo dpkg --install "$workspace/plugin.deb"
test "$(session-manager-plugin --version)" = "$version"
