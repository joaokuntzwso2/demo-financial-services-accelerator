#!/usr/bin/env bash
umask 077
source "$(dirname "$0")/common.sh"
need openssl; need xxd; need docker
D=.state/certs
mkdir -p "$D"
if [[ -s "$D/client-truststore.p12" && -s "$D/wso2apim.p12" && -s "$D/wso2is.p12" && -s "$D/tpp.crt" && -s "$D/directory-jwks.json" && -s "$D/tpp-jwks.json" ]]; then
  log "Demo certificates and JWKS already exist"
  exit 0
fi
rm -f "$D"/*
log "Generating disposable demo PKI"
openssl genrsa -out "$D/ca.key" 4096 >/dev/null 2>&1
openssl req -x509 -new -nodes -key "$D/ca.key" -sha256 -days 3650 -subj '/C=BR/O=WSO2 Demo/CN=WSO2 Open Banking Demo Root CA' -out "$D/ca.crt"
issue(){
  local name=$1 eku=$2 sans=$3
  openssl genrsa -out "$D/$name.key" 2048 >/dev/null 2>&1
  openssl req -new -key "$D/$name.key" -subj "/C=BR/O=WSO2 Demo/CN=$name" -out "$D/$name.csr"
  cat > "$D/$name.ext" <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=$eku
subjectAltName=$sans
EOF
  openssl x509 -req -in "$D/$name.csr" -CA "$D/ca.crt" -CAkey "$D/ca.key" -CAcreateserial -out "$D/$name.crt" -days 825 -sha256 -extfile "$D/$name.ext" >/dev/null 2>&1
}
issue wso2apim serverAuth 'DNS:wso2apim,DNS:localhost,IP:127.0.0.1'
issue wso2is serverAuth 'DNS:wso2is,DNS:localhost,IP:127.0.0.1'
issue tpp 'clientAuth,serverAuth' 'DNS:tpp.local,DNS:localhost,IP:127.0.0.1'
issue directory 'clientAuth,serverAuth' 'DNS:directory.local,DNS:bank-backend,DNS:localhost,IP:127.0.0.1'
for s in wso2apim wso2is; do
  openssl pkcs12 -export -name wso2carbon -inkey "$D/$s.key" -in "$D/$s.crt" -certfile "$D/ca.crt" -out "$D/$s.p12" -passout pass:wso2carbon >/dev/null 2>&1
done

# Use a containerized keytool so the host only needs Docker/OpenSSL rather than a local JDK.
CERT_DIR="$ROOT/$D"
keytool_docker(){ docker run --rm -v "$CERT_DIR:/certs" eclipse-temurin:21-jre keytool "$@"; }
keytool_docker -importcert -noprompt -alias demo-root-ca -file /certs/ca.crt -keystore /certs/client-truststore.p12 -storetype PKCS12 -storepass wso2carbon >/dev/null 2>&1
keytool_docker -importcert -noprompt -alias wso2apim -file /certs/wso2apim.crt -keystore /certs/client-truststore.p12 -storetype PKCS12 -storepass wso2carbon >/dev/null 2>&1
keytool_docker -importcert -noprompt -alias wso2is -file /certs/wso2is.crt -keystore /certs/client-truststore.p12 -storetype PKCS12 -storepass wso2carbon >/dev/null 2>&1
keytool_docker -importcert -noprompt -alias tpp -file /certs/tpp.crt -keystore /certs/client-truststore.p12 -storetype PKCS12 -storepass wso2carbon >/dev/null 2>&1
openssl pkcs12 -export -name tpp -inkey "$D/tpp.key" -in "$D/tpp.crt" -certfile "$D/ca.crt" -out "$D/tpp.p12" -passout pass:changeit >/dev/null 2>&1
openssl x509 -in "$D/tpp.crt" -noout -fingerprint -sha256 > "$D/tpp.sha256"

b64url(){ openssl base64 -A | tr '+/' '-_' | tr -d '='; }
make_jwk(){
  local cert=$1 kid=$2 out=$3 use=${4:-sig}
  local mod n
  mod=$(openssl x509 -in "$cert" -noout -modulus | sed 's/^Modulus=//')
  n=$(printf '%s' "$mod" | xxd -r -p | b64url)
  cat > "$out" <<EOF
{"keys":[{"kty":"RSA","use":"$use","kid":"$kid","alg":"PS256","n":"$n","e":"AQAB"}]}
EOF
}
DIR_KID=$(openssl x509 -in "$D/directory.crt" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256 -binary | b64url)
TPP_KID=$(openssl x509 -in "$D/tpp.crt" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256 -binary | b64url)
make_jwk "$D/directory.crt" "$DIR_KID" "$D/directory-jwks.json"
make_jwk "$D/tpp.crt" "$TPP_KID" "$D/tpp-jwks.json"
printf '%s\n' "$DIR_KID" > "$D/directory.kid"
printf '%s\n' "$TPP_KID" > "$D/tpp.kid"
