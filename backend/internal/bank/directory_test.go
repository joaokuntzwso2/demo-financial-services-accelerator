package bank

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func testDirectoryPublicCert(t *testing.T) string {
	t.Helper()

	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}

	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "JWKS test"},
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

	path := filepath.Join(t.TempDir(), "public.crt")
	if err := os.WriteFile(
		path,
		pem.EncodeToMemory(&pem.Block{
			Type:  "CERTIFICATE",
			Bytes: der,
		}),
		0o600,
	); err != nil {
		t.Fatal(err)
	}

	return path
}

func TestPublicJWKContainsOnlyPublicRSAParameters(t *testing.T) {
	jwk, err := publicJWKFromCertificateFile(testDirectoryPublicCert(t))
	if err != nil {
		t.Fatal(err)
	}

	for _, required := range []string{"kty", "use", "alg", "kid", "n", "e", "x5c"} {
		if _, ok := jwk[required]; !ok {
			t.Fatalf("missing public JWK field %q", required)
		}
	}

	for _, private := range []string{"d", "p", "q", "dp", "dq", "qi", "oth"} {
		if _, ok := jwk[private]; ok {
			t.Fatalf("private JWK field %q must not be exposed", private)
		}
	}
}

func TestServePublicJWKS(t *testing.T) {
	path := testDirectoryPublicCert(t)

	req := httptest.NewRequest(http.MethodGet, "/directory/jwks.json", nil)
	rec := httptest.NewRecorder()

	servePublicJWKS(rec, req, path)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}

	var body struct {
		Keys []map[string]any `json:"keys"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Keys) != 1 {
		t.Fatalf("JWKS key count = %d, want 1", len(body.Keys))
	}
	if body.Keys[0]["alg"] != "PS256" {
		t.Fatalf("alg = %v", body.Keys[0]["alg"])
	}
}
