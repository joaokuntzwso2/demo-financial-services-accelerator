package main

import (
	"encoding/json"
	"testing"
)

func TestPaymentConsentAndSubmissionTermsMatch(t *testing.T) {
	consent := paymentConsentPayload()
	data, ok := consent["Data"].(map[string]any)
	if !ok {
		t.Fatal("payment consent Data missing")
	}
	initiation, ok := data["Initiation"].(map[string]any)
	if !ok {
		t.Fatal("payment consent Initiation missing")
	}
	submission := map[string]any{
		"Data": map[string]any{
			"ConsentId":  "consent-1",
			"Initiation": paymentInitiation(),
		},
		"Risk": map[string]any{},
	}
	subData := submission["Data"].(map[string]any)
	a, _ := json.Marshal(initiation)
	b, _ := json.Marshal(subData["Initiation"])
	if string(a) != string(b) {
		t.Fatalf("payment Initiation differs between consent and submission:\n%s\n%s", a, b)
	}
}

func TestCoFRequestContractHasNoCallerAccountID(t *testing.T) {
	body := map[string]any{
		"Data": map[string]any{
			"ConsentId": "c1",
			"Reference": "r1",
			"InstructedAmount": map[string]any{
				"Amount":   "10.00",
				"Currency": "USD",
			},
		},
	}
	raw, _ := json.Marshal(body)
	var decoded any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatal(err)
	}
	if got := recursiveStringAny(decoded, "AccountId"); got != "" {
		t.Fatalf("CoF request must not contain caller AccountId, got %q", got)
	}
}

func TestOIDCHalfHashDeterministic(t *testing.T) {
	if got := oidcHalfHash("abc"); got != "ungWv48Bz-pBQUDeXa4iIw" {
		t.Fatalf("unexpected half hash: %s", got)
	}
}

func TestCanonicalDomain(t *testing.T) {
	cases := map[string]string{
		"accounts":           "accounts",
		"payments":           "payments",
		"funds":              "cof",
		"fundsconfirmations": "cof",
		"cof":                "cof",
	}
	for input, want := range cases {
		if got := canonicalDomain(input); got != want {
			t.Fatalf("%q: got %q want %q", input, got, want)
		}
	}
}
