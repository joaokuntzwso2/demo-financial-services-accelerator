package bank

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

type API struct {
	mu sync.RWMutex
	s  *Store
}

func NewAPI(s *Store) *API { return &API{s: s} }

func write(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("x-fapi-interaction-id", fmt.Sprintf("demo-%d", time.Now().UnixNano()))
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func errJSON(w http.ResponseWriter, status int, msg string) {
	write(w, status, map[string]any{"Code": strconv.Itoa(status), "Message": msg, "Errors": []any{}})
}
func envelope(data any) map[string]any {
	return map[string]any{"Data": data, "Links": map[string]string{"Self": ""}, "Meta": map[string]any{"TotalPages": 1}}
}

func (a *API) Handler() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { write(w, 200, map[string]any{"status": "ok"}) })
	m.HandleFunc("/demo/summary", a.summary)
	m.HandleFunc("/directory/jwks.json", directoryJWKS)
	m.HandleFunc("/extensions/populate-consent-authorize-screen", a.populateConsentAuthorizeScreen)
	m.HandleFunc("/extensions/validate-consent-access", a.validateConsentAccess)
	baseA := "/api/fs/backend/services/accounts/accountservice"
	m.HandleFunc(baseA+"/accounts", a.accounts)
	m.HandleFunc(baseA+"/accounts/", a.accountSubresource)
	m.HandleFunc(baseA+"/beneficiaries", a.allBeneficiaries)
	baseP := "/api/fs/backend/services/payments/paymentservice"
	m.HandleFunc(baseP+"/domestic-payments", a.payments)
	m.HandleFunc(baseP+"/domestic-payments/", a.paymentByID)
	baseF := "/api/fs/backend/services/fundsConfirmation/fundsconfirmationservice"
	m.HandleFunc(baseF+"/funds-confirmations", a.funds)
	return requestLog(m)
}

func requestLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s %s", r.Method, r.URL.Path, time.Since(start))
	})
}
func (a *API) summary(w http.ResponseWriter, r *http.Request) {
	a.mu.RLock()
	defer a.mu.RUnlock()
	write(w, 200, map[string]any{"customers": 8, "accounts": len(a.s.Accounts), "transactions": len(a.s.Transactions), "beneficiaries": len(a.s.Beneficiaries), "payments": len(a.s.Payments), "scenario": "Acme Bank / FinLink TPP"})
}
func (a *API) accounts(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		errJSON(
			w,
			http.StatusMethodNotAllowed,
			"method not allowed",
		)
		return
	}

	ctx, allowed, err := accountConsentFromRequest(r)
	if err != nil {
		errJSON(
			w,
			http.StatusUnauthorized,
			"invalid account consent context",
		)
		return
	}

	if !hasAnyConsentPermission(
		ctx,
		"ReadAccountsBasic",
		"ReadAccountsDetail",
	) {
		errJSON(
			w,
			http.StatusForbidden,
			"account read permission not granted by consent",
		)
		return
	}

	a.mu.RLock()
	defer a.mu.RUnlock()

	out := make(
		[]Account,
		0,
		len(allowed),
	)

	for _, account := range a.s.Accounts {
		if _, ok := allowed[account.AccountID]; ok {
			out = append(
				out,
				account,
			)
		}
	}

	write(
		w,
		http.StatusOK,
		envelope(
			map[string]any{
				"Account": out,
			},
		),
	)
}

func (a *API) accountSubresource(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		errJSON(
			w,
			http.StatusMethodNotAllowed,
			"method not allowed",
		)
		return
	}

	prefix :=
		"/api/fs/backend/services/accounts/accountservice/accounts/"

	rest := strings.TrimPrefix(
		r.URL.Path,
		prefix,
	)

	parts := strings.Split(
		strings.Trim(rest, "/"),
		"/",
	)

	if len(parts) < 1 ||
		parts[0] == "" {
		errJSON(
			w,
			http.StatusNotFound,
			"account not found",
		)
		return
	}

	accountID := parts[0]

	ctx, allowed, err :=
		accountConsentFromRequest(r)

	if err != nil {
		errJSON(
			w,
			http.StatusUnauthorized,
			"invalid account consent context",
		)
		return
	}

	if _, ok := allowed[accountID]; !ok {
		errJSON(
			w,
			http.StatusForbidden,
			"account not permitted by consent",
		)
		return
	}

	a.mu.RLock()
	defer a.mu.RUnlock()

	var account *Account

	for i := range a.s.Accounts {
		if a.s.Accounts[i].AccountID !=
			accountID {
			continue
		}

		value := a.s.Accounts[i]
		account = &value
		break
	}

	if account == nil {
		errJSON(
			w,
			http.StatusNotFound,
			"account not found",
		)
		return
	}

	if len(parts) == 1 {
		if !hasAnyConsentPermission(
			ctx,
			"ReadAccountsBasic",
			"ReadAccountsDetail",
		) {
			errJSON(
				w,
				http.StatusForbidden,
				"account read permission not granted by consent",
			)
			return
		}

		write(
			w,
			http.StatusOK,
			envelope(
				map[string]any{
					"Account": []Account{
						*account,
					},
				},
			),
		)
		return
	}

	switch parts[1] {
	case "balances":
		if !hasAnyConsentPermission(
			ctx,
			"ReadBalances",
		) {
			errJSON(
				w,
				http.StatusForbidden,
				"ReadBalances permission not granted by consent",
			)
			return
		}

		indicator := "Credit"
		amount := account.Balance

		if amount < 0 {
			indicator = "Debit"
			amount = -amount
		}

		data := map[string]any{
			"Balance": []any{
				map[string]any{
					"AccountId":            accountID,
					"CreditDebitIndicator": indicator,
					"Type":                 "InterimAvailable",
					"DateTime":             now(),
					"Amount": Amount{
						Amount: fmt.Sprintf(
							"%.2f",
							amount,
						),
						Currency: account.Currency,
					},
				},
			},
		}

		write(
			w,
			http.StatusOK,
			envelope(data),
		)

	case "transactions":
		if !hasAnyConsentPermission(
			ctx,
			"ReadTransactionsBasic",
			"ReadTransactionsDetail",
		) {
			errJSON(
				w,
				http.StatusForbidden,
				"transaction read permission not granted by consent",
			)
			return
		}

		out := make(
			[]Transaction,
			0,
		)

		allowCredits :=
			hasAnyConsentPermission(
				ctx,
				"ReadTransactionsCredits",
			)

		allowDebits :=
			hasAnyConsentPermission(
				ctx,
				"ReadTransactionsDebits",
			)

		directionalFilter :=
			allowCredits || allowDebits

		for _, tx := range a.s.Transactions {
			if tx.AccountID != accountID {
				continue
			}

			if !transactionWithinConsentWindow(
				ctx,
				tx,
			) {
				continue
			}

			if directionalFilter {
				if strings.EqualFold(
					tx.CreditDebitIndicator,
					"Credit",
				) && !allowCredits {
					continue
				}

				if strings.EqualFold(
					tx.CreditDebitIndicator,
					"Debit",
				) && !allowDebits {
					continue
				}
			}

			out = append(out, tx)
		}

		write(
			w,
			http.StatusOK,
			envelope(
				map[string]any{
					"Transaction": out,
				},
			),
		)

	case "beneficiaries":
		// The current demo permission catalogue intentionally contains only
		// the validated Accounts/Balance/Transaction permission set.
		//
		// We therefore enforce account membership here without inventing a
		// beneficiary permission the FS profile is not currently configured
		// to issue.
		out := make(
			[]Beneficiary,
			0,
		)

		for _, beneficiary := range a.s.Beneficiaries {
			if beneficiary.AccountID ==
				accountID {
				out = append(
					out,
					beneficiary,
				)
			}
		}

		write(
			w,
			http.StatusOK,
			envelope(
				map[string]any{
					"Beneficiary": out,
				},
			),
		)

	default:
		errJSON(
			w,
			http.StatusNotFound,
			"resource not found",
		)
	}
}

func (a *API) allBeneficiaries(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		errJSON(
			w,
			http.StatusMethodNotAllowed,
			"method not allowed",
		)
		return
	}

	_, allowed, err :=
		accountConsentFromRequest(r)

	if err != nil {
		errJSON(
			w,
			http.StatusUnauthorized,
			"invalid account consent context",
		)
		return
	}

	a.mu.RLock()
	defer a.mu.RUnlock()

	out := make(
		[]Beneficiary,
		0,
	)

	for _, beneficiary := range a.s.Beneficiaries {
		if _, ok := allowed[beneficiary.AccountID]; ok {
			out = append(
				out,
				beneficiary,
			)
		}
	}

	write(
		w,
		http.StatusOK,
		envelope(
			map[string]any{
				"Beneficiary": out,
			},
		),
	)
}

func (a *API) payments(w http.ResponseWriter, r *http.Request) {
	ctx, err :=
		consentContextFromRequest(
			r,
			"payments",
		)

	if err != nil {
		errJSON(
			w,
			http.StatusUnauthorized,
			"invalid payment consent context",
		)
		return
	}

	switch r.Method {
	case http.MethodGet:
		a.mu.RLock()
		defer a.mu.RUnlock()

		out := make(
			[]Payment,
			0,
		)

		for _, payment := range a.s.Payments {
			if payment.ConsentID ==
				ctx.ConsentID {
				out = append(
					out,
					payment,
				)
			}
		}

		write(
			w,
			http.StatusOK,
			envelope(
				map[string]any{
					"DomesticPayment": out,
				},
			),
		)

	case http.MethodPost:
		var request PaymentRequest

		if err := json.NewDecoder(
			r.Body,
		).Decode(&request); err != nil {
			errJSON(
				w,
				http.StatusBadRequest,
				"invalid JSON",
			)
			return
		}

		if request.ConsentID == "" ||
			request.InstructionIdentification == "" ||
			request.EndToEndIdentification == "" ||
			request.DebtorAccount == "" ||
			request.CreditorAccount == "" ||
			request.InstructedAmount.Amount == "" ||
			request.InstructedAmount.Currency == "" {
			errJSON(
				w,
				http.StatusBadRequest,
				"ConsentId, payment identifiers, debtor, creditor and amount are required",
			)
			return
		}

		if err :=
			authorizePaymentRequest(
				ctx,
				request,
			); err != nil {
			errJSON(
				w,
				consentHTTPStatus(err),
				"payment request not permitted by consent",
			)
			return
		}

		amount, err := strconv.ParseFloat(
			request.InstructedAmount.Amount,
			64,
		)

		if err != nil ||
			amount <= 0 {
			errJSON(
				w,
				http.StatusBadRequest,
				"invalid amount",
			)
			return
		}

		idempotencyKey := strings.TrimSpace(
			r.Header.Get(
				"x-idempotency-key",
			),
		)

		if idempotencyKey == "" {
			errJSON(
				w,
				http.StatusBadRequest,
				"x-idempotency-key is required",
			)
			return
		}

		// Do not allow an idempotency key from one PSU consent to retrieve or
		// collide with the payment created under another consent.
		scopedKey :=
			ctx.ConsentID +
				"\x00" +
				idempotencyKey

		a.mu.Lock()
		defer a.mu.Unlock()

		if paymentID, ok :=
			a.s.idempotency[scopedKey]; ok {
			for _, payment := range a.s.Payments {
				if payment.PaymentID ==
					paymentID &&
					payment.ConsentID ==
						ctx.ConsentID {
					write(
						w,
						http.StatusOK,
						envelope(
							map[string]any{
								"DomesticPayment": payment,
							},
						),
					)
					return
				}
			}
		}

		accountIndex := -1

		for i := range a.s.Accounts {
			if accountMatchesIdentification(
				a.s.Accounts[i],
				request.DebtorAccount,
			) {
				accountIndex = i
				break
			}
		}

		if accountIndex < 0 {
			errJSON(
				w,
				http.StatusNotFound,
				"debtor account not found",
			)
			return
		}

		if !strings.EqualFold(
			a.s.Accounts[accountIndex].Currency,
			request.InstructedAmount.Currency,
		) {
			errJSON(
				w,
				http.StatusBadRequest,
				"payment currency does not match debtor account currency",
			)
			return
		}

		if a.s.Accounts[accountIndex].Balance < amount {
			errJSON(
				w,
				http.StatusUnprocessableEntity,
				"insufficient funds",
			)
			return
		}

		// State mutation happens only after all signed-consent checks have
		// completed successfully.
		a.s.Accounts[accountIndex].Balance -= amount

		paymentID := fmt.Sprintf(
			"PAY-%06d",
			len(a.s.Payments)+1,
		)

		payment := Payment{
			PaymentID: paymentID,
			ConsentID: ctx.ConsentID,

			Status: "AcceptedSettlementCompleted",

			CreationDateTime: now(),

			StatusUpdateDateTime: now(),

			InstructionIdentification: request.InstructionIdentification,

			EndToEndIdentification: request.EndToEndIdentification,

			DebtorAccount: request.DebtorAccount,

			CreditorName: request.CreditorName,

			CreditorAccount: request.CreditorAccount,

			InstructedAmount: request.InstructedAmount,

			Reference: request.Reference,
		}

		a.s.Payments = append(
			a.s.Payments,
			payment,
		)

		a.s.idempotency[scopedKey] = paymentID

		a.s.Transactions = append(
			a.s.Transactions,
			Transaction{
				TransactionID: "TX-" + paymentID,

				AccountID: request.DebtorAccount,

				Status: "Booked",

				BookingDateTime: now(),

				ValueDateTime: now(),

				CreditDebitIndicator: "Debit",

				Amount: request.InstructedAmount,

				TransactionInformation: request.Reference,

				MerchantName: request.CreditorName,
			},
		)

		write(
			w,
			http.StatusCreated,
			envelope(
				map[string]any{
					"DomesticPayment": payment,
				},
			),
		)

	default:
		errJSON(
			w,
			http.StatusMethodNotAllowed,
			"method not allowed",
		)
	}
}

func (a *API) paymentByID(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		errJSON(
			w,
			http.StatusMethodNotAllowed,
			"method not allowed",
		)
		return
	}

	ctx, err :=
		consentContextFromRequest(
			r,
			"payments",
		)

	if err != nil {
		errJSON(
			w,
			http.StatusUnauthorized,
			"invalid payment consent context",
		)
		return
	}

	paymentID := strings.TrimPrefix(
		r.URL.Path,
		"/api/fs/backend/services/payments/paymentservice/domestic-payments/",
	)

	a.mu.RLock()
	defer a.mu.RUnlock()

	for _, payment := range a.s.Payments {
		if payment.PaymentID !=
			paymentID {
			continue
		}

		if payment.ConsentID !=
			ctx.ConsentID {
			errJSON(
				w,
				http.StatusForbidden,
				"payment not permitted by consent",
			)
			return
		}

		write(
			w,
			http.StatusOK,
			envelope(
				map[string]any{
					"DomesticPayment": payment,
				},
			),
		)
		return
	}

	errJSON(
		w,
		http.StatusNotFound,
		"payment not found",
	)
}

func (a *API) funds(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		errJSON(
			w,
			http.StatusMethodNotAllowed,
			"method not allowed",
		)
		return
	}

	var request FundsRequest

	if err := json.NewDecoder(
		r.Body,
	).Decode(&request); err != nil {
		errJSON(
			w,
			http.StatusBadRequest,
			"invalid JSON",
		)
		return
	}

	if request.InstructedAmount.Amount == "" ||
		request.InstructedAmount.Currency == "" {
		errJSON(
			w,
			http.StatusBadRequest,
			"InstructedAmount is required",
		)
		return
	}

	// Standards-facing OBFundsConfirmation1 requests require both
	// Data.ConsentId and Data.Reference. Legacy flat decoding exists
	// only for direct/internal test compatibility.
	if request.structured &&
		(request.ConsentID == "" ||
			request.Reference == "") {
		errJSON(
			w,
			http.StatusBadRequest,
			"ConsentId and Reference are required",
		)
		return
	}

	ctx, err :=
		consentContextFromRequest(
			r,
			"fundsconfirmations",
		)

	if err != nil {
		errJSON(
			w,
			http.StatusUnauthorized,
			"invalid funds-confirmation consent context",
		)
		return
	}

	debtorIdentification, err :=
		authorizeFundsRequest(
			ctx,
			request,
		)

	if err != nil {
		errJSON(
			w,
			consentHTTPStatus(err),
			"funds-confirmation request not permitted by consent",
		)
		return
	}

	amount, err := strconv.ParseFloat(
		request.InstructedAmount.Amount,
		64,
	)

	if err != nil ||
		amount <= 0 {
		errJSON(
			w,
			http.StatusBadRequest,
			"invalid amount",
		)
		return
	}

	a.mu.RLock()
	defer a.mu.RUnlock()

	for _, account := range a.s.Accounts {
		// The account comes exclusively from the signed authorised
		// consent, never from caller-controlled protected-resource data.
		if !accountMatchesIdentification(
			account,
			debtorIdentification,
		) {
			continue
		}

		if !strings.EqualFold(
			account.Currency,
			request.InstructedAmount.Currency,
		) {
			errJSON(
				w,
				http.StatusBadRequest,
				"funds-confirmation currency does not match account currency",
			)
			return
		}

		fundsConfirmationID := fmt.Sprintf(
			"FCONF-%d",
			time.Now().UTC().UnixNano(),
		)

		write(
			w,
			http.StatusCreated,
			envelope(
				map[string]any{
					"FundsConfirmationId": fundsConfirmationID,
					"ConsentId":           ctx.ConsentID,

					"CreationDateTime": now(),

					"FundsAvailable": account.Balance >=
						amount,

					"Reference": request.Reference,

					"InstructedAmount": request.InstructedAmount,
				},
			),
		)
		return
	}

	errJSON(
		w,
		http.StatusNotFound,
		"account not found",
	)
}

// The demo directory key is intentionally non-secret and static. Real SSA trust must come from a regulatory directory.
func directoryJWKS(w http.ResponseWriter, r *http.Request) {
	write(w, 200, map[string]any{"keys": []any{}})
}
