package bank

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
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
	api := NewAPI(Seed(1))
	srv := httptest.NewServer(api.Handler())
	defer srv.Close()
	r, e := http.Get(srv.URL + "/api/fs/backend/services/accounts/accountservice/accounts")
	if e != nil || r.StatusCode != 200 {
		t.Fatalf("accounts: %v status %v", e, r.StatusCode)
	}
	body := `{"AccountId":"ACC-001","InstructedAmount":{"Amount":"1.00","Currency":"BRL"}}`
	r, e = http.Post(srv.URL+"/api/fs/backend/services/fundsConfirmation/fundsconfirmationservice/funds-confirmations", "application/json", strings.NewReader(body))
	if e != nil || r.StatusCode != 200 {
		t.Fatalf("funds: %v status %v", e, r.StatusCode)
	}
	var v map[string]any
	if json.NewDecoder(r.Body).Decode(&v) != nil {
		t.Fatal("bad json")
	}
}
