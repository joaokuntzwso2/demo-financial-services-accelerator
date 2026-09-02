package main

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"strings"
	"testing"
	"time"
)

func testSigningCert(t *testing.T) (*rsa.PrivateKey, *x509.Certificate) {
	t.Helper()

	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}

	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: big.NewInt(42),
		Subject:      pkix.Name{CommonName: "dcrsign-test"},
		NotBefore:    now.Add(-time.Minute),
		NotAfter:     now.Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
	}

	der, err := x509.CreateCertificate(
		rand.Reader,
		template,
		template,
		&key.PublicKey,
		key,
	)
	if err != nil {
		t.Fatal(err)
	}

	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}

	return key, cert
}

func TestSignPS256RoundTrip(t *testing.T) {
	key, cert := testSigningCert(t)
	payload := []byte(`{"iss":"finlink","jti":"123"}`)

	token, err := signPS256(
		key,
		certificateKID(cert),
		payload,
	)
	if err != nil {
		t.Fatal(err)
	}

	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("token parts = %d", len(parts))
	}

	input := parts[0] + "." + parts[1]
	sum := sha256.Sum256([]byte(input))

	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		t.Fatal(err)
	}

	if err := rsa.VerifyPSS(
		&key.PublicKey,
		crypto.SHA256,
		sum[:],
		signature,
		&rsa.PSSOptions{
			SaltLength: rsa.PSSSaltLengthEqualsHash,
			Hash:       crypto.SHA256,
		},
	); err != nil {
		t.Fatal(err)
	}

	headerRaw, _ := base64.RawURLEncoding.DecodeString(parts[0])
	var header map[string]any
	if err := json.Unmarshal(headerRaw, &header); err != nil {
		t.Fatal(err)
	}

	if header["alg"] != "PS256" {
		t.Fatalf("alg = %v", header["alg"])
	}
	if header["kid"] != certificateKID(cert) {
		t.Fatalf("kid = %v", header["kid"])
	}
}

func TestPublicJWKHasNoPrivateParameters(t *testing.T) {
	_, cert := testSigningCert(t)

	jwk, err := publicJWK(cert)
	if err != nil {
		t.Fatal(err)
	}

	for _, private := range []string{
		"d", "p", "q", "dp", "dq", "qi",
	} {
		if _, ok := jwk[private]; ok {
			t.Fatalf(
				"private JWK parameter %q exposed",
				private,
			)
		}
	}
}
