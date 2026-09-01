package bank

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

func installDomainTestCertificate(
	t *testing.T,
) *rsa.PrivateKey {
	t.Helper()

	key, certPath :=
		newTestISCertificate(t)

	t.Setenv(
		"FS_ARI_CERT_FILE",
		certPath,
	)

	accountRequestKeyOnce = sync.Once{}
	accountRequestKey = nil
	accountRequestKeyErr = nil

	return key
}

func signDomainConsentInformation(
	t *testing.T,
	key *rsa.PrivateKey,
	payload map[string]any,
) string {
	t.Helper()

	headerJSON, err := json.Marshal(
		map[string]any{
			"alg": "RS256",
		},
	)
	if err != nil {
		t.Fatalf(
			"marshal header: %v",
			err,
		)
	}

	payloadJSON, err :=
		json.Marshal(payload)
	if err != nil {
		t.Fatalf(
			"marshal payload: %v",
			err,
		)
	}

	headerPart :=
		base64.RawURLEncoding.EncodeToString(
			headerJSON,
		)

	payloadPart :=
		base64.RawURLEncoding.EncodeToString(
			payloadJSON,
		)

	signingInput :=
		headerPart + "." + payloadPart

	digest :=
		sha256.Sum256(
			[]byte(signingInput),
		)

	signature, err :=
		rsa.SignPKCS1v15(
			rand.Reader,
			key,
			crypto.SHA256,
			digest[:],
		)

	if err != nil {
		t.Fatalf(
			"sign consent information: %v",
			err,
		)
	}

	return signingInput +
		"." +
		base64.RawURLEncoding.EncodeToString(
			signature,
		)
}

func requestWithDomainARI(
	t *testing.T,
	method string,
	url string,
	ari string,
	body string,
	idempotencyKey string,
) *http.Response {
	t.Helper()

	request, err := http.NewRequest(
		method,
		url,
		strings.NewReader(body),
	)
	if err != nil {
		t.Fatalf(
			"create request: %v",
			err,
		)
	}

	if ari != "" {
		request.Header.Set(
			accountRequestInformationHeader,
			ari,
		)
	}

	if idempotencyKey != "" {
		request.Header.Set(
			"x-idempotency-key",
			idempotencyKey,
		)
	}

	request.Header.Set(
		"Content-Type",
		"application/json",
	)

	response, err :=
		http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf(
			"execute request: %v",
			err,
		)
	}

	return response
}

func TestAccountPermissionEnforcement(
	t *testing.T,
) {
	signingKey :=
		installDomainTestCertificate(t)

	api := NewAPI(Seed(1))

	server :=
		httptest.NewServer(
			api.Handler(),
		)
	defer server.Close()

	makeARI := func(
		permissions []any,
	) string {
		return signDomainConsentInformation(
			t,
			signingKey,
			map[string]any{
				"clientId": "test-client",

				"currentStatus": "Authorised",

				"consent_type": "accounts",

				"consentId": "account-consent",

				"receipt": map[string]any{
					"Data": map[string]any{
						"Permissions": permissions,

						"ExpirationDateTime": "2099-01-01T00:00:00Z",

						"TransactionFromDateTime": "2020-01-01T00:00:00Z",

						"TransactionToDateTime": "2098-01-01T00:00:00Z",
					},
				},

				"authorizationResources": []any{
					map[string]any{
						"authorizationId": "auth-1",

						"authorizationStatus": "Authorised",
					},
				},

				"consentMappingResources": []any{
					map[string]any{
						"authorizationId": "auth-1",

						"mappingStatus": "active",

						"permission": "primary",

						"account_id": "ACC-001",
					},
				},
			},
		)
	}

	baseURL :=
		server.URL +
			"/api/fs/backend/services/accounts/accountservice/accounts/ACC-001"

	t.Run(
		"account read permission",
		func(t *testing.T) {
			response :=
				requestWithDomainARI(
					t,
					http.MethodGet,
					baseURL,
					makeARI(
						[]any{
							"ReadBalances",
						},
					),
					"",
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
		"balance denied without ReadBalances",
		func(t *testing.T) {
			response :=
				requestWithDomainARI(
					t,
					http.MethodGet,
					baseURL+
						"/balances",
					makeARI(
						[]any{
							"ReadAccountsBasic",
						},
					),
					"",
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
		"balance allowed with ReadBalances",
		func(t *testing.T) {
			response :=
				requestWithDomainARI(
					t,
					http.MethodGet,
					baseURL+
						"/balances",
					makeARI(
						[]any{
							"ReadBalances",
						},
					),
					"",
					"",
				)
			defer response.Body.Close()

			if response.StatusCode !=
				http.StatusOK {
				t.Fatalf(
					"expected 200, got %d",
					response.StatusCode,
				)
			}
		},
	)

	t.Run(
		"transactions denied without transaction permission",
		func(t *testing.T) {
			response :=
				requestWithDomainARI(
					t,
					http.MethodGet,
					baseURL+
						"/transactions",
					makeARI(
						[]any{
							"ReadAccountsBasic",
						},
					),
					"",
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
		"transactions allowed with transaction permission",
		func(t *testing.T) {
			response :=
				requestWithDomainARI(
					t,
					http.MethodGet,
					baseURL+
						"/transactions",
					makeARI(
						[]any{
							"ReadTransactionsBasic",
						},
					),
					"",
					"",
				)
			defer response.Body.Close()

			if response.StatusCode !=
				http.StatusOK {
				t.Fatalf(
					"expected 200, got %d",
					response.StatusCode,
				)
			}
		},
	)
}

func TestPaymentConsentEnforcement(
	t *testing.T,
) {
	signingKey :=
		installDomainTestCertificate(t)

	api := NewAPI(Seed(1))

	server :=
		httptest.NewServer(
			api.Handler(),
		)
	defer server.Close()

	receipt := map[string]any{
		"Data": map[string]any{
			"Initiation": map[string]any{
				"InstructionIdentification": "INST-001",

				"EndToEndIdentification": "E2E-001",

				"InstructedAmount": map[string]any{
					"Amount": "149.90",

					"Currency": "BRL",
				},

				"DebtorAccount": map[string]any{
					"Identification": "ACC-001",
				},

				"CreditorAccount": map[string]any{
					"Identification": "BR1234567890",

					"Name": "Energia Sul",
				},

				"RemittanceInformation": map[string]any{
					"Reference": "Electricity invoice AUG-2026",
				},
			},
		},
	}

	ari := signDomainConsentInformation(
		t,
		signingKey,
		map[string]any{
			"clientId": "test-client",

			"currentStatus": "Authorised",

			"consent_type": "payments",

			"consentId": "payment-consent",

			"receipt": receipt,
		},
	)

	body := `{
		"ConsentId":"payment-consent",
		"InstructionIdentification":"INST-001",
		"EndToEndIdentification":"E2E-001",
		"DebtorAccount":"ACC-001",
		"CreditorName":"Energia Sul",
		"CreditorAccount":"BR1234567890",
		"InstructedAmount":{
			"Amount":"149.90",
			"Currency":"BRL"
		},
		"Reference":"Electricity invoice AUG-2026"
	}`

	url :=
		server.URL +
			"/api/fs/backend/services/payments/paymentservice/domestic-payments"

	startBalance := api.s.Accounts[0].Balance

	response :=
		requestWithDomainARI(
			t,
			http.MethodPost,
			url,
			ari,
			body,
			"idem-001",
		)

	if response.StatusCode !=
		http.StatusCreated {
		response.Body.Close()

		t.Fatalf(
			"expected 201, got %d",
			response.StatusCode,
		)
	}

	var created struct {
		Data struct {
			DomesticPayment Payment `json:"DomesticPayment"`
		} `json:"Data"`
	}

	if err := json.NewDecoder(
		response.Body,
	).Decode(&created); err != nil {
		response.Body.Close()

		t.Fatalf(
			"decode payment: %v",
			err,
		)
	}

	response.Body.Close()

	if created.Data.DomesticPayment.ConsentID !=
		"payment-consent" {
		t.Fatalf(
			"payment stored wrong consent: %q",
			created.Data.DomesticPayment.ConsentID,
		)
	}

	afterFirstPayment :=
		api.s.Accounts[0].Balance

	if !(afterFirstPayment <
		startBalance) {
		t.Fatal(
			"payment did not debit debtor account",
		)
	}

	t.Run(
		"idempotency is replay-safe",
		func(t *testing.T) {
			response :=
				requestWithDomainARI(
					t,
					http.MethodPost,
					url,
					ari,
					body,
					"idem-001",
				)
			defer response.Body.Close()

			if response.StatusCode !=
				http.StatusOK {
				t.Fatalf(
					"expected 200, got %d",
					response.StatusCode,
				)
			}

			if api.s.Accounts[0].Balance !=
				afterFirstPayment {
				t.Fatal(
					"idempotent replay debited account twice",
				)
			}
		},
	)

	t.Run(
		"tampered amount is forbidden",
		func(t *testing.T) {
			tampered :=
				strings.Replace(
					body,
					"149.90",
					"150.90",
					1,
				)

			response :=
				requestWithDomainARI(
					t,
					http.MethodPost,
					url,
					ari,
					tampered,
					"idem-002",
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
		"tampered creditor is forbidden",
		func(t *testing.T) {
			tampered :=
				strings.Replace(
					body,
					"BR1234567890",
					"ATTACKER",
					1,
				)

			response :=
				requestWithDomainARI(
					t,
					http.MethodPost,
					url,
					ari,
					tampered,
					"idem-003",
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
		"missing ARI fails closed",
		func(t *testing.T) {
			response :=
				requestWithDomainARI(
					t,
					http.MethodPost,
					url,
					"",
					body,
					"idem-004",
				)
			defer response.Body.Close()

			if response.StatusCode !=
				http.StatusUnauthorized {
				t.Fatalf(
					"expected 401, got %d",
					response.StatusCode,
				)
			}
		},
	)

	t.Run(
		"payment status bound to creating consent",
		func(t *testing.T) {
			statusURL :=
				url +
					"/" +
					created.Data.DomesticPayment.PaymentID

			response :=
				requestWithDomainARI(
					t,
					http.MethodGet,
					statusURL,
					ari,
					"",
					"",
				)
			defer response.Body.Close()

			if response.StatusCode !=
				http.StatusOK {
				t.Fatalf(
					"expected 200, got %d",
					response.StatusCode,
				)
			}

			otherARI :=
				signDomainConsentInformation(
					t,
					signingKey,
					map[string]any{
						"currentStatus": "Authorised",

						"consent_type": "payments",

						"consentId": "other-payment-consent",

						"receipt": receipt,
					},
				)

			response =
				requestWithDomainARI(
					t,
					http.MethodGet,
					statusURL,
					otherARI,
					"",
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
}

func TestFundsConfirmationConsentEnforcement(
	t *testing.T,
) {
	signingKey :=
		installDomainTestCertificate(t)

	api := NewAPI(Seed(1))

	server :=
		httptest.NewServer(
			api.Handler(),
		)
	defer server.Close()

	payload := map[string]any{
		"clientId": "test-client",

		"currentStatus": "Authorised",

		"consent_type": "fundsconfirmations",

		"consentId": "cof-consent",

		"receipt": map[string]any{
			"Data": map[string]any{
				"ExpirationDateTime": "2099-01-01T00:00:00Z",

				"DebtorAccount": map[string]any{
					"Identification": "ACC-001",
				},
			},
		},
	}

	ari :=
		signDomainConsentInformation(
			t,
			signingKey,
			payload,
		)

	url :=
		server.URL +
			"/api/fs/backend/services/fundsConfirmation/fundsconfirmationservice/funds-confirmations"

	body := `{
		"AccountId":"ACC-001",
		"InstructedAmount":{
			"Amount":"10.00",
			"Currency":"BRL"
		}
	}`

	t.Run(
		"authorised account succeeds",
		func(t *testing.T) {
			response :=
				requestWithDomainARI(
					t,
					http.MethodPost,
					url,
					ari,
					body,
					"",
				)
			defer response.Body.Close()

			if response.StatusCode !=
				http.StatusOK {
				t.Fatalf(
					"expected 200, got %d",
					response.StatusCode,
				)
			}
		},
	)

	t.Run(
		"different account is forbidden",
		func(t *testing.T) {
			tampered :=
				strings.Replace(
					body,
					"ACC-001",
					"ACC-004",
					1,
				)

			response :=
				requestWithDomainARI(
					t,
					http.MethodPost,
					url,
					ari,
					tampered,
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
		"missing ARI fails closed",
		func(t *testing.T) {
			response :=
				requestWithDomainARI(
					t,
					http.MethodPost,
					url,
					"",
					body,
					"",
				)
			defer response.Body.Close()

			if response.StatusCode !=
				http.StatusUnauthorized {
				t.Fatalf(
					"expected 401, got %d",
					response.StatusCode,
				)
			}
		},
	)

	t.Run(
		"expired consent fails closed",
		func(t *testing.T) {
			expiredPayload :=
				map[string]any{
					"currentStatus": "Authorised",

					"consent_type": "fundsconfirmations",

					"consentId": "expired-cof",

					"receipt": map[string]any{
						"Data": map[string]any{
							"ExpirationDateTime": "2020-01-01T00:00:00Z",

							"DebtorAccount": map[string]any{
								"Identification": "ACC-001",
							},
						},
					},
				}

			expiredARI :=
				signDomainConsentInformation(
					t,
					signingKey,
					expiredPayload,
				)

			response :=
				requestWithDomainARI(
					t,
					http.MethodPost,
					url,
					expiredARI,
					body,
					"",
				)
			defer response.Body.Close()

			if response.StatusCode !=
				http.StatusUnauthorized {
				t.Fatalf(
					"expected 401, got %d",
					response.StatusCode,
				)
			}
		},
	)
}
