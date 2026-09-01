package bank

import (
	"encoding/json"
	"net/http"
	"os"
	"strings"
)

type consentAuthorizeExtensionRequest struct {
	RequestID string `json:"requestId"`
	Data      struct {
		ConsentID         string         `json:"consentId"`
		UserID            string         `json:"userId"`
		RequestParameters map[string]any `json:"requestParameters"`
		ConsentResource   map[string]any `json:"consentResource"`
	} `json:"data"`
}

func extensionCredential(name, fallback string) string {
	v := strings.TrimSpace(os.Getenv(name))
	if v == "" {
		return fallback
	}
	return v
}

func normalizeDemoUser(userID string) string {
	userID = strings.TrimSpace(userID)
	userID = strings.TrimSuffix(userID, "@carbon.super")

	if i := strings.Index(userID, "@"); i >= 0 {
		userID = userID[:i]
	}

	return strings.ToLower(userID)
}

func demoCustomerForUser(userID string) string {
	switch normalizeDemoUser(userID) {
	case "alice":
		return "CUS-001"
	case "bob":
		return "CUS-002"
	case "carol":
		return "CUS-003"
	case "demo":
		return "CUS-004"
	default:
		return ""
	}
}

func receiptObject(resource map[string]any) map[string]any {
	if resource == nil {
		return nil
	}

	v, ok := resource["receipt"]
	if !ok {
		return nil
	}

	switch receipt := v.(type) {
	case map[string]any:
		return receipt

	case string:
		var decoded map[string]any
		if json.Unmarshal([]byte(receipt), &decoded) == nil {
			return decoded
		}
	}

	return nil
}

// addConsentDisplayItem appends one entry using the list-oriented
// {title, data} model consumed by the Financial Services authorization UI.
func addConsentDisplayItem(
	out *[]map[string]any,
	title string,
	values ...any,
) {
	if len(values) == 0 {
		return
	}

	*out = append(*out, map[string]any{
		"title": title,
		"data":  values,
	})
}

func receiptData(receipt map[string]any) map[string]any {
	if receipt == nil {
		return nil
	}

	data, _ := receipt["Data"].(map[string]any)
	return data
}

func stringField(data map[string]any, field string) string {
	if data == nil {
		return ""
	}

	value, _ := data[field].(string)
	return strings.TrimSpace(value)
}

func appendRawField(
	out *[]map[string]any,
	data map[string]any,
	title string,
	field string,
) {
	if data == nil {
		return
	}

	value, ok := data[field]
	if !ok || value == nil {
		return
	}

	switch v := value.(type) {
	case []any:
		if len(v) != 0 {
			*out = append(*out, map[string]any{
				"title": title,
				"data":  v,
			})
		}
	default:
		addConsentDisplayItem(out, title, v)
	}
}

func appendAccountDisplay(
	out *[]map[string]any,
	parent map[string]any,
	field string,
	title string,
) {
	raw, ok := parent[field]
	if !ok || raw == nil {
		return
	}

	account, ok := raw.(map[string]any)
	if !ok {
		return
	}

	values := make([]any, 0, 4)

	if value := stringField(account, "SchemeName"); value != "" {
		values = append(values, "Scheme Name :"+value)
	}
	if value := stringField(account, "Identification"); value != "" {
		values = append(values, "Identification :"+value)
	}
	if value := stringField(account, "Name"); value != "" {
		values = append(values, "Name :"+value)
	}
	if value := stringField(account, "SecondaryIdentification"); value != "" {
		values = append(values, "Secondary Identification :"+value)
	}

	addConsentDisplayItem(out, title, values...)
}

// buildAccountConsentDisplayData mirrors the stock FS Accelerator 4.0.0
// Accounts consent display while allowing the external step to replace the
// stock dummy account list with real demo-bank accounts.
func buildAccountConsentDisplayData(receipt map[string]any) []map[string]any {
	out := make([]map[string]any, 0)
	data := receiptData(receipt)

	appendRawField(&out, data, "Permissions", "Permissions")
	appendRawField(&out, data, "Expiration Date Time", "ExpirationDateTime")
	appendRawField(
		&out,
		data,
		"Transaction From Date Time",
		"TransactionFromDateTime",
	)
	appendRawField(
		&out,
		data,
		"Transaction To Date Time",
		"TransactionToDateTime",
	)

	return out
}

// buildPaymentConsentDisplayData mirrors the stock FS Accelerator 4.0.0
// Payments consent display.
func buildPaymentConsentDisplayData(receipt map[string]any) []map[string]any {
	out := make([]map[string]any, 0)
	data := receiptData(receipt)

	if data == nil {
		return out
	}

	initiation, _ := data["Initiation"].(map[string]any)
	if initiation == nil {
		return out
	}

	if value := stringField(initiation, "InstructionIdentification"); value != "" {
		addConsentDisplayItem(&out, "Instruction Identification", value)
	}

	if value := stringField(initiation, "EndToEndIdentification"); value != "" {
		addConsentDisplayItem(&out, "End to End Identification", value)
	}

	if raw, ok := initiation["InstructedAmount"]; ok {
		if amount, ok := raw.(map[string]any); ok {
			values := make([]any, 0, 2)

			if value := stringField(amount, "Amount"); value != "" {
				values = append(values, "Amount :"+value)
			}
			if value := stringField(amount, "Currency"); value != "" {
				values = append(values, "Currency :"+value)
			}

			addConsentDisplayItem(&out, "Instructed Amount", values...)
		}
	}

	appendAccountDisplay(
		&out,
		initiation,
		"DebtorAccount",
		"Debtor Account",
	)

	appendAccountDisplay(
		&out,
		initiation,
		"CreditorAccount",
		"Creditor Account",
	)

	return out
}

// buildFundsConsentDisplayData mirrors the stock FS Accelerator 4.0.0
// Confirmation of Funds consent display.
func buildFundsConsentDisplayData(receipt map[string]any) []map[string]any {
	out := make([]map[string]any, 0)
	data := receiptData(receipt)

	if data == nil {
		return out
	}

	if value := stringField(data, "ExpirationDateTime"); value != "" {
		addConsentDisplayItem(&out, "Expiration Date Time", value)
	} else {
		addConsentDisplayItem(
			&out,
			"Expiration Date Time",
			"Open Ended Authorisation Requested",
		)
	}

	appendAccountDisplay(
		&out,
		data,
		"DebtorAccount",
		"Debtor Account",
	)

	return out
}

func consentResourceType(resource map[string]any) string {
	value, _ := resource["type"].(string)
	return strings.ToLower(strings.TrimSpace(value))
}

func (a *API) populateConsentAuthorizeScreen(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		errJSON(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	expectedUser := extensionCredential("FS_EXTENSION_USER", "fs-extension")
	expectedPass := extensionCredential("FS_EXTENSION_PASSWORD", "fs-extension-secret")

	user, pass, ok := r.BasicAuth()
	if !ok || user != expectedUser || pass != expectedPass {
		w.Header().Set("WWW-Authenticate", `Basic realm="fs-extension"`)
		errJSON(w, http.StatusUnauthorized, "invalid extension credentials")
		return
	}

	var req consentAuthorizeExtensionRequest

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		errJSON(w, http.StatusBadRequest, "invalid extension request")
		return
	}

	customerID := demoCustomerForUser(req.Data.UserID)
	if customerID == "" {
		errJSON(w, http.StatusBadRequest, "no demo customer mapped to user")
		return
	}

	a.mu.RLock()

	accounts := make([]map[string]any, 0)

	for _, account := range a.s.Accounts {
		if account.CustomerID != customerID {
			continue
		}

		accounts = append(accounts, map[string]any{
			"account_id":   account.AccountID,
			"display_name": account.Nickname,
		})
	}

	a.mu.RUnlock()

	if len(accounts) == 0 {
		errJSON(w, http.StatusBadRequest, "no shareable accounts for user")
		return
	}

	receipt := receiptObject(req.Data.ConsentResource)

	var consentData []map[string]any

	switch consentResourceType(req.Data.ConsentResource) {
	case "accounts":
		consentData = buildAccountConsentDisplayData(receipt)

	case "payments":
		consentData = buildPaymentConsentDisplayData(receipt)

	case "fundsconfirmations":
		consentData = buildFundsConsentDisplayData(receipt)

	default:
		errJSON(w, http.StatusBadRequest, "unsupported consent type")
		return
	}

	write(w, http.StatusOK, map[string]any{
		"responseId": req.RequestID,
		"status":     "SUCCESS",
		"data": map[string]any{
			"consentData":  consentData,
			"consumerData": accounts,
		},
	})

}
