package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func TestGatewayJSONWithApplicationTokenRefreshesOnceAfter401(t *testing.T) {
	var tokenRequests atomic.Int32
	var gatewayRequests atomic.Int32

	mux := http.NewServeMux()

	server := httptest.NewServer(mux)
	defer server.Close()

	mux.HandleFunc("/oauth2/token", func(w http.ResponseWriter, r *http.Request) {
		tokenRequests.Add(1)

		if err := r.ParseForm(); err != nil {
			t.Fatalf("parse token form: %v", err)
		}
		if got := r.Form.Get("grant_type"); got != "client_credentials" {
			t.Fatalf("grant_type = %q", got)
		}
		if got := r.Form.Get("scope"); got != "accounts" {
			t.Fatalf("scope = %q", got)
		}

		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"access_token": "fresh-application-token",
			"expires_in":   300,
			"scope":        "accounts",
		})
	})

	mux.HandleFunc("/consent", func(w http.ResponseWriter, r *http.Request) {
		gatewayRequests.Add(1)

		switch r.Header.Get("Authorization") {
		case "Bearer stale-application-token":
			http.Error(w, `{"code":"900901","message":"Invalid Credentials"}`, http.StatusUnauthorized)
		case "Bearer fresh-application-token":
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"Status":"Authorised"}`))
		default:
			http.Error(w, "unexpected authorization header", http.StatusForbidden)
		}
	})

	p := &Portal{
		cfg: Config{
			IS:       server.URL,
			ClientID: "finlink-test-client",
		},
		appTokens: map[string]AppToken{
			"accounts": {
				Token:  "stale-application-token",
				Expiry: time.Now().Add(10 * time.Minute),
			},
		},
		mtlsClient: server.Client(),
		httpClient: server.Client(),
	}

	code, raw, err := p.gatewayJSONWithApplicationToken(
		context.Background(),
		"accounts",
		http.MethodGet,
		server.URL+"/consent",
		nil,
		nil,
	)
	if err != nil {
		t.Fatalf("gatewayJSONWithApplicationToken: %v", err)
	}
	if code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", code, raw)
	}
	if tokenRequests.Load() != 1 {
		t.Fatalf("token endpoint requests = %d, want 1", tokenRequests.Load())
	}
	if gatewayRequests.Load() != 2 {
		t.Fatalf("gateway requests = %d, want 2", gatewayRequests.Load())
	}

	p.mu.RLock()
	cached := p.appTokens["accounts"]
	p.mu.RUnlock()

	if cached.Token != "fresh-application-token" {
		t.Fatalf("cached token = %q, want fresh token", cached.Token)
	}
}

func TestInvalidateApplicationTokenDoesNotDeleteNewerToken(t *testing.T) {
	p := &Portal{
		appTokens: map[string]AppToken{
			"accounts": {
				Token:  "newer-token",
				Expiry: time.Now().Add(10 * time.Minute),
			},
		},
	}

	p.invalidateApplicationToken("accounts", "older-token")

	p.mu.RLock()
	cached, ok := p.appTokens["accounts"]
	p.mu.RUnlock()

	if !ok {
		t.Fatal("newer cached token was deleted")
	}
	if cached.Token != "newer-token" {
		t.Fatalf("cached token = %q", cached.Token)
	}
}
