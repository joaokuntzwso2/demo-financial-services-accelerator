package bank

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestFundsConfirmationStructuredWireContract(
	t *testing.T,
) {
	signingKey :=
		installDomainTestCertificate(t)

	store := Seed(1)

	var account Account
	found := false

	for _, candidate := range store.Accounts {
		if candidate.Identification == "" ||
			candidate.Currency == "" ||
			candidate.Balance <= 100 {
			continue
		}

		account = candidate
		found = true
		break
	}

	if !found {
		t.Fatal(
			"test seed contains no suitable funded account",
		)
	}

	api := NewAPI(store)

	server :=
		httptest.NewServer(
			api.Handler(),
		)

	defer server.Close()

	consentID := "cof-wire-consent"

	ari :=
		signDomainConsentInformation(
			t,
			signingKey,
			map[string]any{
				"clientId": "test-client",

				"currentStatus": "Authorised",

				"consent_type": "fundsconfirmations",

				"consentId": consentID,

				"receipt": map[string]any{
					"Data": map[string]any{
						"ExpirationDateTime": "2099-01-01T00:00:00Z",

						"DebtorAccount": map[string]any{
							"Identification": account.Identification,
						},
					},
				},
			},
		)

	resourceURL :=
		server.URL +
			"/api/fs/backend/services/" +
			"fundsConfirmation/" +
			"fundsconfirmationservice/" +
			"funds-confirmations"

	makeBody := func(
		consent string,
		reference string,
		amount string,
		currency string,
	) string {
		t.Helper()

		raw, err :=
			json.Marshal(
				map[string]any{
					"Data": map[string]any{
						"ConsentId": consent,

						"Reference": reference,

						"InstructedAmount": map[string]any{
							"Amount": amount,

							"Currency": currency,
						},
					},
				},
			)

		if err != nil {
			t.Fatalf(
				"marshal funds request: %v",
				err,
			)
		}

		return string(raw)
	}

	t.Run(
		"structured request returns 201 and true",
		func(t *testing.T) {
			response :=
				requestWithDomainARI(
					t,
					http.MethodPost,
					resourceURL,
					ari,
					makeBody(
						consentID,
						"COF-TRUE",
						"1.00",
						account.Currency,
					),
					"",
				)

			defer response.Body.Close()

			if response.StatusCode !=
				http.StatusCreated {
				t.Fatalf(
					"expected 201, got %d",
					response.StatusCode,
				)
			}

			var payload struct {
				Data struct {
					FundsConfirmationID string `json:"FundsConfirmationId"`

					ConsentID string `json:"ConsentId"`

					FundsAvailable bool `json:"FundsAvailable"`

					Reference string `json:"Reference"`

					InstructedAmount Amount `json:"InstructedAmount"`
				} `json:"Data"`
			}

			if err :=
				json.NewDecoder(
					response.Body,
				).Decode(
					&payload,
				); err != nil {
				t.Fatalf(
					"decode response: %v",
					err,
				)
			}

			if payload.Data.FundsConfirmationID == "" {
				t.Fatal(
					"FundsConfirmationId is missing",
				)
			}

			if payload.Data.ConsentID != consentID {
				t.Fatalf(
					"unexpected ConsentId %q",
					payload.Data.ConsentID,
				)
			}

			if payload.Data.Reference !=
				"COF-TRUE" {
				t.Fatalf(
					"unexpected Reference %q",
					payload.Data.Reference,
				)
			}

			if !payload.Data.FundsAvailable {
				t.Fatal(
					"expected FundsAvailable=true",
				)
			}
		},
	)

	t.Run(
		"body consent mismatch is forbidden",
		func(t *testing.T) {
			response :=
				requestWithDomainARI(
					t,
					http.MethodPost,
					resourceURL,
					ari,
					makeBody(
						"other-consent",
						"COF-WRONG-CONSENT",
						"1.00",
						account.Currency,
					),
					"",
				)

			defer response.Body.Close()

			if response.StatusCode !=
				http.StatusForbidden {
				t.Fatalf(
					"expected 403, got %d",
					response.StatusCode,
				)
			}
		},
	)

	t.Run(
		"insufficient funds returns 201 and false",
		func(t *testing.T) {
			response :=
				requestWithDomainARI(
					t,
					http.MethodPost,
					resourceURL,
					ari,
					makeBody(
						consentID,
						"COF-FALSE",
						"9999999999999.00",
						account.Currency,
					),
					"",
				)

			defer response.Body.Close()

			if response.StatusCode !=
				http.StatusCreated {
				t.Fatalf(
					"expected 201, got %d",
					response.StatusCode,
				)
			}

			var payload struct {
				Data struct {
					FundsAvailable bool `json:"FundsAvailable"`
				} `json:"Data"`
			}

			if err :=
				json.NewDecoder(
					response.Body,
				).Decode(
					&payload,
				); err != nil {
				t.Fatalf(
					"decode response: %v",
					err,
				)
			}

			if payload.Data.FundsAvailable {
				t.Fatal(
					"expected FundsAvailable=false",
				)
			}
		},
	)

	t.Run(
		"account currency mismatch is rejected",
		func(t *testing.T) {
			wrongCurrency := "EUR"

			if account.Currency == "EUR" {
				wrongCurrency = "USD"
			}

			response :=
				requestWithDomainARI(
					t,
					http.MethodPost,
					resourceURL,
					ari,
					makeBody(
						consentID,
						"COF-WRONG-CURRENCY",
						"1.00",
						wrongCurrency,
					),
					"",
				)

			defer response.Body.Close()

			if response.StatusCode !=
				http.StatusBadRequest {
				t.Fatalf(
					"expected 400, got %d",
					response.StatusCode,
				)
			}
		},
	)
}
