package bank

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestSeedVolume(t *testing.T) {
	s := Seed(1)

	if len(s.Accounts) < 20 {
		t.Fatalf("expected >=20 accounts, got %d", len(s.Accounts))
	}

	if len(s.Transactions) < 400 {
		t.Fatalf("expected >=400 transactions, got %d", len(s.Transactions))
	}
}

func TestAccountsAndFunds(t *testing.T) {
	signingKey, certPath := newTestISCertificate(t)

	t.Setenv("FS_ARI_CERT_FILE", certPath)

	// Reset the production key cache so this test uses the temporary
	// certificate generated above.
	accountRequestKeyOnce = sync.Once{}
	accountRequestKey = nil
	accountRequestKeyErr = nil

	api := NewAPI(Seed(1))
	srv := httptest.NewServer(api.Handler())
	defer srv.Close()

	accountsURL := srv.URL +
		"/api/fs/backend/services/accounts/accountservice/accounts"

	validARI := signAccountRequestInformation(
		t,
		signingKey,
		[]string{"ACC-001", "ACC-002", "ACC-003"},
	)

	t.Run("valid signed ARI filters collection", func(t *testing.T) {
		r := getWithARI(t, accountsURL, validARI)
		defer r.Body.Close()

		if r.StatusCode != http.StatusOK {
			t.Fatalf("expected 200, got %d", r.StatusCode)
		}

		var response struct {
			Data struct {
				Account []Account `json:"Account"`
			} `json:"Data"`
		}

		if err := json.NewDecoder(r.Body).Decode(&response); err != nil {
			t.Fatalf("decode accounts response: %v", err)
		}

		if len(response.Data.Account) != 3 {
			t.Fatalf(
				"expected exactly 3 consented accounts, got %d",
				len(response.Data.Account),
			)
		}

		expected := map[string]bool{
			"ACC-001": true,
			"ACC-002": true,
			"ACC-003": true,
		}

		for _, account := range response.Data.Account {
			if !expected[account.AccountID] {
				t.Fatalf(
					"unexpected account returned: %s",
					account.AccountID,
				)
			}
		}
	})

	t.Run("mapped account is allowed", func(t *testing.T) {
		r := getWithARI(t, accountsURL+"/ACC-001", validARI)
		defer r.Body.Close()

		if r.StatusCode != http.StatusOK {
			t.Fatalf("expected 200, got %d", r.StatusCode)
		}
	})

	t.Run("unmapped account is forbidden", func(t *testing.T) {
		r := getWithARI(t, accountsURL+"/ACC-004", validARI)
		defer r.Body.Close()

		if r.StatusCode != http.StatusForbidden {
			t.Fatalf("expected 403, got %d", r.StatusCode)
		}
	})

	t.Run("missing ARI fails closed", func(t *testing.T) {
		r := getWithARI(t, accountsURL, "")
		defer r.Body.Close()

		if r.StatusCode != http.StatusUnauthorized {
			t.Fatalf("expected 401, got %d", r.StatusCode)
		}
	})

	t.Run("invalid ARI signature fails closed", func(t *testing.T) {
		attackerKey, err := rsa.GenerateKey(rand.Reader, 2048)
		if err != nil {
			t.Fatalf("generate attacker key: %v", err)
		}

		badARI := signAccountRequestInformation(
			t,
			attackerKey,
			[]string{"ACC-001", "ACC-004"},
		)

		r := getWithARI(t, accountsURL, badARI)
		defer r.Body.Close()

		if r.StatusCode != http.StatusUnauthorized {
			t.Fatalf("expected 401, got %d", r.StatusCode)
		}
	})

	// Funds Confirmation is intentionally unaffected by the Accounts
	// resource-membership enforcement.
	body := `{"AccountId":"ACC-001","InstructedAmount":{"Amount":"1.00","Currency":"BRL"}}`

	r, err := http.Post(
		srv.URL+
			"/api/fs/backend/services/fundsConfirmation/fundsconfirmationservice/funds-confirmations",
		"application/json",
		strings.NewReader(body),
	)
	if err != nil {
		t.Fatalf("funds request: %v", err)
	}
	defer r.Body.Close()

	if r.StatusCode != http.StatusOK {
		t.Fatalf("funds: expected 200, got %d", r.StatusCode)
	}

	var v map[string]any

	if err := json.NewDecoder(r.Body).Decode(&v); err != nil {
		t.Fatalf("bad funds JSON: %v", err)
	}
}

func getWithARI(t *testing.T, url, ari string) *http.Response {
	t.Helper()

	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		t.Fatalf("create request: %v", err)
	}

	if ari != "" {
		req.Header.Set("Account-Request-Information", ari)
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("execute request: %v", err)
	}

	return resp
}

func newTestISCertificate(t *testing.T) (*rsa.PrivateKey, string) {
	t.Helper()

	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate RSA key: %v", err)
	}

	now := time.Now()

	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			CommonName: "test-wso2is",
		},
		NotBefore: now.Add(-time.Minute),
		NotAfter:  now.Add(time.Hour),
		KeyUsage:  x509.KeyUsageDigitalSignature,
	}

	der, err := x509.CreateCertificate(
		rand.Reader,
		template,
		template,
		&key.PublicKey,
		key,
	)
	if err != nil {
		t.Fatalf("create certificate: %v", err)
	}

	certPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE",
		Bytes: der,
	})

	path := filepath.Join(t.TempDir(), "wso2is.crt")

	if err := os.WriteFile(path, certPEM, 0600); err != nil {
		t.Fatalf("write certificate: %v", err)
	}

	return key, path
}

func signAccountRequestInformation(
	t *testing.T,
	key *rsa.PrivateKey,
	accountIDs []string,
) string {
	t.Helper()

	const authorizationID = "test-authorization"

	mappings := make([]map[string]any, 0, len(accountIDs))

	for _, accountID := range accountIDs {
		mappings = append(mappings, map[string]any{
			"mappingStatus":   "active",
			"account_id":      accountID,
			"authorizationId": authorizationID,
			"permission":      "primary",
		})
	}

	header := map[string]any{
		"alg": "RS256",
	}

	payload := map[string]any{
		"clientId":      "test-client",
		"currentStatus": "Authorised",
		"consent_type":  "accounts",
		"consentId":     "test-consent",
		"authorizationResources": []map[string]any{
			{
				"authorizationId":     authorizationID,
				"authorizationStatus": "Authorised",
			},
		},
		"consentMappingResources": mappings,
	}

	headerJSON, err := json.Marshal(header)
	if err != nil {
		t.Fatalf("marshal header: %v", err)
	}

	payloadJSON, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}

	headerPart := base64.RawURLEncoding.EncodeToString(headerJSON)
	payloadPart := base64.RawURLEncoding.EncodeToString(payloadJSON)

	signingInput := headerPart + "." + payloadPart
	digest := sha256.Sum256([]byte(signingInput))

	signature, err := rsa.SignPKCS1v15(
		rand.Reader,
		key,
		crypto.SHA256,
		digest[:],
	)
	if err != nil {
		t.Fatalf("sign ARI: %v", err)
	}

	return signingInput + "." +
		base64.RawURLEncoding.EncodeToString(signature)
}
