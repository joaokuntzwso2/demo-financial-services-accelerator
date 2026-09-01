package bank

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func callConsentAccessExtension(
	t *testing.T,
	api *API,
	body map[string]any,
) map[string]any {
	t.Helper()

	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}

	req := httptest.NewRequest(
		http.MethodPost,
		"/extensions/validate-consent-access",
		bytes.NewReader(raw),
	)
	req.SetBasicAuth(
		"fs-extension",
		"fs-extension-secret",
	)

	rec := httptest.NewRecorder()

	api.validateConsentAccess(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf(
			"extension transport: expected 200, got %d: %s",
			rec.Code,
			rec.Body.String(),
		)
	}

	var response map[string]any
	if err := json.Unmarshal(
		rec.Body.Bytes(),
		&response,
	); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	return response
}

func consentAccessTestRequest(
	consentType string,
	path string,
	receipt map[string]any,
	body map[string]any,
) map[string]any {
	dataRequest := map[string]any{
		"headers":         map[string]any{},
		"consentId":       "consent-1",
		"clientId":        "client-1",
		"resourceParams":  map[string]string{},
		"userId":          "bob",
		"electedResource": path,
	}

	if body != nil {
		dataRequest["body"] = body
	}

	return map[string]any{
		"requestId": "request-1",
		"data": map[string]any{
			"consentId": "consent-1",
			"consentResource": map[string]any{
				"id":       "consent-1",
				"clientId": "client-1",
				"type":     consentType,
				"status":   "Authorised",
				"receipt":  receipt,
			},
			"dataRequestPayload": dataRequest,
		},
	}
}

func TestValidateConsentAccessPaymentSubmissionAndRetrieval(
	t *testing.T,
) {
	api := NewAPI(Seed(1))

	initiation := map[string]any{
		"InstructionIdentification": "INST-1",
		"EndToEndIdentification":    "E2E-1",
		"InstructedAmount": map[string]any{
			"Amount":   "10.00",
			"Currency": "USD",
		},
	}

	receipt := map[string]any{
		"Data": map[string]any{
			"Initiation": initiation,
		},
	}

	submission := map[string]any{
		"Data": map[string]any{
			"ConsentId":  "consent-1",
			"Initiation": initiation,
		},
		"Risk": map[string]any{},
	}

	response := callConsentAccessExtension(
		t,
		api,
		consentAccessTestRequest(
			"payments",
			"/domestic-payments",
			receipt,
			submission,
		),
	)

	if response["status"] != "SUCCESS" {
		t.Fatalf(
			"expected payment submission SUCCESS: %#v",
			response,
		)
	}

	response = callConsentAccessExtension(
		t,
		api,
		consentAccessTestRequest(
			"payments",
			"/domestic-payments/PAY-000001",
			receipt,
			map[string]any{},
		),
	)

	if response["status"] != "SUCCESS" {
		t.Fatalf(
			"expected payment retrieval SUCCESS: %#v",
			response,
		)
	}

	tampered := map[string]any{
		"Data": map[string]any{
			"ConsentId": "consent-1",
			"Initiation": map[string]any{
				"InstructionIdentification": "INST-1",
				"EndToEndIdentification":    "E2E-1",
				"InstructedAmount": map[string]any{
					"Amount":   "11.00",
					"Currency": "USD",
				},
			},
		},
	}

	response = callConsentAccessExtension(
		t,
		api,
		consentAccessTestRequest(
			"payments",
			"/domestic-payments",
			receipt,
			tampered,
		),
	)

	if response["status"] != "ERROR" {
		t.Fatalf(
			"expected tampered payment ERROR: %#v",
			response,
		)
	}
}

func TestValidateConsentAccessAccountsPermissions(
	t *testing.T,
) {
	api := NewAPI(Seed(1))

	receipt := map[string]any{
		"Data": map[string]any{
			"Permissions": []any{
				"ReadAccountsBasic",
				"ReadAccountsDetail",
				"ReadTransactionsDetail",
			},
			"ExpirationDateTime": time.Now().
				UTC().
				Add(time.Hour).
				Format(time.RFC3339),
		},
	}

	response := callConsentAccessExtension(
		t,
		api,
		consentAccessTestRequest(
			"accounts",
			"/accounts/ACC-001/transactions",
			receipt,
			map[string]any{},
		),
	)

	if response["status"] != "SUCCESS" {
		t.Fatalf(
			"expected account transaction SUCCESS: %#v",
			response,
		)
	}

	response = callConsentAccessExtension(
		t,
		api,
		consentAccessTestRequest(
			"accounts",
			"/accounts/ACC-001/balances",
			receipt,
			map[string]any{},
		),
	)

	if response["status"] != "ERROR" {
		t.Fatalf(
			"expected missing ReadBalances ERROR: %#v",
			response,
		)
	}
}

func TestValidateConsentAccessFundsConfirmation(
	t *testing.T,
) {
	api := NewAPI(Seed(1))

	receipt := map[string]any{
		"Data": map[string]any{
			"ExpirationDateTime": time.Now().
				UTC().
				Add(time.Hour).
				Format(time.RFC3339),
		},
	}

	body := map[string]any{
		"Data": map[string]any{
			"ConsentId": "consent-1",
		},
	}

	response := callConsentAccessExtension(
		t,
		api,
		consentAccessTestRequest(
			"fundsconfirmations",
			"/funds-confirmations",
			receipt,
			body,
		),
	)

	if response["status"] != "SUCCESS" {
		t.Fatalf(
			"expected funds confirmation SUCCESS: %#v",
			response,
		)
	}
}
