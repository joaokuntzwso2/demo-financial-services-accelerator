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
	if r.Method != "GET" {
		errJSON(w, 405, "method not allowed")
		return
	}
	a.mu.RLock()
	defer a.mu.RUnlock()
	write(w, 200, envelope(map[string]any{"Account": a.s.Accounts}))
}

func (a *API) accountSubresource(w http.ResponseWriter, r *http.Request) {
	if r.Method != "GET" {
		errJSON(w, 405, "method not allowed")
		return
	}
	prefix := "/api/fs/backend/services/accounts/accountservice/accounts/"
	rest := strings.TrimPrefix(r.URL.Path, prefix)
	parts := strings.Split(strings.Trim(rest, "/"), "/")
	if len(parts) < 1 || parts[0] == "" {
		errJSON(w, 404, "account not found")
		return
	}
	id := parts[0]
	a.mu.RLock()
	defer a.mu.RUnlock()
	var acc *Account
	for i := range a.s.Accounts {
		if a.s.Accounts[i].AccountID == id {
			x := a.s.Accounts[i]
			acc = &x
			break
		}
	}
	if acc == nil {
		errJSON(w, 404, "account not found")
		return
	}
	if len(parts) == 1 {
		write(w, 200, envelope(map[string]any{"Account": []Account{*acc}}))
		return
	}
	switch parts[1] {
	case "balances":
		ind := "Credit"
		amt := acc.Balance
		if amt < 0 {
			ind = "Debit"
			amt = -amt
		}
		data := map[string]any{"Balance": []any{map[string]any{"AccountId": id, "CreditDebitIndicator": ind, "Type": "InterimAvailable", "DateTime": now(), "Amount": Amount{Amount: fmt.Sprintf("%.2f", amt), Currency: acc.Currency}}}}
		write(w, 200, envelope(data))
	case "transactions":
		out := make([]Transaction, 0)
		for _, t := range a.s.Transactions {
			if t.AccountID == id {
				out = append(out, t)
			}
		}
		write(w, 200, envelope(map[string]any{"Transaction": out}))
	case "beneficiaries":
		out := make([]Beneficiary, 0)
		for _, b := range a.s.Beneficiaries {
			if b.AccountID == id {
				out = append(out, b)
			}
		}
		write(w, 200, envelope(map[string]any{"Beneficiary": out}))
	default:
		errJSON(w, 404, "resource not found")
	}
}
func (a *API) allBeneficiaries(w http.ResponseWriter, r *http.Request) {
	a.mu.RLock()
	defer a.mu.RUnlock()
	write(w, 200, envelope(map[string]any{"Beneficiary": a.s.Beneficiaries}))
}

func (a *API) payments(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case "GET":
		a.mu.RLock()
		defer a.mu.RUnlock()
		write(w, 200, envelope(map[string]any{"DomesticPayment": a.s.Payments}))
	case "POST":
		var pr PaymentRequest
		if json.NewDecoder(r.Body).Decode(&pr) != nil {
			errJSON(w, 400, "invalid JSON")
			return
		}
		if pr.DebtorAccount == "" || pr.InstructedAmount.Amount == "" {
			errJSON(w, 400, "DebtorAccount and InstructedAmount are required")
			return
		}
		key := r.Header.Get("x-idempotency-key")
		a.mu.Lock()
		defer a.mu.Unlock()
		if key != "" {
			if id, ok := a.s.idempotency[key]; ok {
				for _, p := range a.s.Payments {
					if p.PaymentID == id {
						write(w, 200, envelope(map[string]any{"DomesticPayment": p}))
						return
					}
				}
			}
		}
		amount, e := strconv.ParseFloat(pr.InstructedAmount.Amount, 64)
		if e != nil || amount <= 0 {
			errJSON(w, 400, "invalid amount")
			return
		}
		idx := -1
		for i := range a.s.Accounts {
			if a.s.Accounts[i].AccountID == pr.DebtorAccount {
				idx = i
				break
			}
		}
		if idx < 0 {
			errJSON(w, 404, "debtor account not found")
			return
		}
		if a.s.Accounts[idx].Balance < amount {
			errJSON(w, 422, "insufficient funds")
			return
		}
		a.s.Accounts[idx].Balance -= amount
		id := fmt.Sprintf("PAY-%06d", len(a.s.Payments)+1)
		p := Payment{PaymentID: id, ConsentID: pr.ConsentID, Status: "AcceptedSettlementCompleted", CreationDateTime: now(), StatusUpdateDateTime: now(), DebtorAccount: pr.DebtorAccount, CreditorName: pr.CreditorName, CreditorAccount: pr.CreditorAccount, InstructedAmount: pr.InstructedAmount, Reference: pr.Reference}
		a.s.Payments = append(a.s.Payments, p)
		if key != "" {
			a.s.idempotency[key] = id
		}
		a.s.Transactions = append(a.s.Transactions, Transaction{TransactionID: "TX-" + id, AccountID: pr.DebtorAccount, Status: "Booked", BookingDateTime: now(), ValueDateTime: now(), CreditDebitIndicator: "Debit", Amount: pr.InstructedAmount, TransactionInformation: pr.Reference, MerchantName: pr.CreditorName})
		write(w, 201, envelope(map[string]any{"DomesticPayment": p}))
	default:
		errJSON(w, 405, "method not allowed")
	}
}
func (a *API) paymentByID(w http.ResponseWriter, r *http.Request) {
	if r.Method != "GET" {
		errJSON(w, 405, "method not allowed")
		return
	}
	id := strings.TrimPrefix(r.URL.Path, "/api/fs/backend/services/payments/paymentservice/domestic-payments/")
	a.mu.RLock()
	defer a.mu.RUnlock()
	for _, p := range a.s.Payments {
		if p.PaymentID == id {
			write(w, 200, envelope(map[string]any{"DomesticPayment": p}))
			return
		}
	}
	errJSON(w, 404, "payment not found")
}
func (a *API) funds(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		errJSON(w, 405, "method not allowed")
		return
	}
	var fr FundsRequest
	if json.NewDecoder(r.Body).Decode(&fr) != nil {
		errJSON(w, 400, "invalid JSON")
		return
	}
	amount, e := strconv.ParseFloat(fr.InstructedAmount.Amount, 64)
	if e != nil {
		errJSON(w, 400, "invalid amount")
		return
	}
	a.mu.RLock()
	defer a.mu.RUnlock()
	for _, x := range a.s.Accounts {
		if x.AccountID == fr.AccountID {
			write(w, 200, envelope(map[string]any{"FundsAvailableResult": map[string]any{"FundsAvailable": x.Balance >= amount, "AccountId": fr.AccountID, "ReferenceDateTime": now()}}))
			return
		}
	}
	errJSON(w, 404, "account not found")
}

// The demo directory key is intentionally non-secret and static. Real SSA trust must come from a regulatory directory.
func directoryJWKS(w http.ResponseWriter, r *http.Request) {
	write(w, 200, map[string]any{"keys": []any{}})
}
