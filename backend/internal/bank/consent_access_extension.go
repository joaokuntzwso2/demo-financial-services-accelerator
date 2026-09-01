package bank

import (
	"encoding/json"
	"net/http"
	"reflect"
	"regexp"
	"strings"
	"time"
)

type consentAccessExtensionRequest struct {
	RequestID string `json:"requestId"`
	Data      struct {
		ConsentID       string                `json:"consentId"`
		ConsentResource consentAccessResource `json:"consentResource"`
		DataRequest     consentAccessRequest  `json:"dataRequestPayload"`
	} `json:"data"`
}

type consentAccessResource struct {
	ID       string         `json:"id"`
	ClientID string         `json:"clientId"`
	Type     string         `json:"type"`
	Status   string         `json:"status"`
	Receipt  map[string]any `json:"receipt"`
}

type consentAccessRequest struct {
	Headers         map[string]any    `json:"headers"`
	ConsentID       string            `json:"consentId"`
	ClientID        string            `json:"clientId"`
	ResourceParams  map[string]string `json:"resourceParams"`
	UserID          string            `json:"userId"`
	ElectedResource string            `json:"electedResource"`
	Body            map[string]any    `json:"body,omitempty"`
}

var (
	consentAccessAccountID = regexp.MustCompile(
		`^/accounts/[^/?]+$`,
	)
	consentAccessTransactions = regexp.MustCompile(
		`^/accounts/[^/?]+/transactions$`,
	)
	consentAccessBalances = regexp.MustCompile(
		`^/accounts/[^/?]+/balances$`,
	)
	consentAccessPaymentID = regexp.MustCompile(
		`^/domestic-payments/[^/?]+$`,
	)
)

func writeConsentAccessSuccess(
	w http.ResponseWriter,
	requestID string,
) {
	write(w, http.StatusOK, map[string]any{
		"responseId": requestID,
		"status":     "SUCCESS",
		"data":       map[string]any{},
	})
}

func writeConsentAccessError(
	w http.ResponseWriter,
	requestID string,
	code int,
	message string,
) {
	errorMessage := "invalid_request"

	switch code {
	case http.StatusUnauthorized:
		errorMessage = "unauthorized"
	case http.StatusForbidden:
		errorMessage = "forbidden"
	}

	// The Accelerator requires HTTP 200 from the extension transport.
	// Domain validation failure is represented by status/errorCode/data.
	write(w, http.StatusOK, map[string]any{
		"responseId": requestID,
		"status":     "ERROR",
		"errorCode":  code,
		"data": map[string]any{
			"errorMessage":     errorMessage,
			"errorDescription": message,
		},
	})
}

func consentAccessMap(
	parent map[string]any,
	field string,
) map[string]any {
	if parent == nil {
		return nil
	}

	value, ok := parent[field].(map[string]any)
	if !ok {
		return nil
	}

	return value
}

func consentAccessString(
	parent map[string]any,
	field string,
) string {
	if parent == nil {
		return ""
	}

	value, _ := parent[field].(string)
	return strings.TrimSpace(value)
}

func consentAccessReceiptData(
	resource consentAccessResource,
) map[string]any {
	return consentAccessMap(resource.Receipt, "Data")
}

func consentAccessHasPermission(
	data map[string]any,
	permission string,
) bool {
	raw, ok := data["Permissions"].([]any)
	if !ok {
		return false
	}

	for _, item := range raw {
		value, ok := item.(string)
		if ok && value == permission {
			return true
		}
	}

	return false
}

func consentAccessExpiration(
	data map[string]any,
	required bool,
) (bool, error) {
	value := consentAccessString(data, "ExpirationDateTime")

	if value == "" {
		return !required, nil
	}

	expiration, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return false, err
	}

	return time.Now().UTC().Before(expiration), nil
}

func consentAccessBodyIsEmpty(body map[string]any) bool {
	return len(body) == 0
}

func validateAccountConsentAccess(
	req consentAccessExtensionRequest,
) (int, string) {
	data := consentAccessReceiptData(req.Data.ConsentResource)
	if data == nil {
		return http.StatusBadRequest, "Consent receipt Data object is missing"
	}

	path := strings.TrimSpace(
		req.Data.DataRequest.ElectedResource,
	)

	switch {
	case path == "/accounts":
		if !consentAccessHasPermission(data, "ReadAccountsBasic") {
			return http.StatusForbidden,
				"Permission mismatch. Consent does not contain ReadAccountsBasic"
		}

	case consentAccessTransactions.MatchString(path):
		if !consentAccessHasPermission(data, "ReadTransactionsDetail") {
			return http.StatusForbidden,
				"Permission mismatch. Consent does not contain ReadTransactionsDetail"
		}

	case consentAccessBalances.MatchString(path):
		if !consentAccessHasPermission(data, "ReadBalances") {
			return http.StatusForbidden,
				"Permission mismatch. Consent does not contain ReadBalances"
		}

	case consentAccessAccountID.MatchString(path):
		if !consentAccessHasPermission(data, "ReadAccountsDetail") {
			return http.StatusForbidden,
				"Permission mismatch. Consent does not contain ReadAccountsDetail"
		}

	default:
		return http.StatusUnauthorized,
			"Path requested is invalid for accounts consent"
	}

	valid, err := consentAccessExpiration(data, true)
	if err != nil {
		return http.StatusBadRequest,
			"Invalid consent expiration date"
	}
	if !valid {
		return http.StatusBadRequest,
			"Provided consent is expired"
	}

	return 0, ""
}

func validatePaymentConsentAccess(
	req consentAccessExtensionRequest,
) (int, string) {
	resource := req.Data.ConsentResource
	path := strings.TrimSpace(
		req.Data.DataRequest.ElectedResource,
	)
	body := req.Data.DataRequest.Body

	// /domestic-payments is both the submission resource and, in this
	// demo API, the collection retrieval resource. ConsentValidateData
	// has no HTTP method, so a missing/empty payload distinguishes the
	// retrieval operation from payment submission.
	if path == "/domestic-payments" &&
		consentAccessBodyIsEmpty(body) {
		return 0, ""
	}

	if consentAccessPaymentID.MatchString(path) {
		if !consentAccessBodyIsEmpty(body) {
			return http.StatusBadRequest,
				"Payment retrieval must not contain a submission body"
		}

		return 0, ""
	}

	if path != "/domestic-payments" {
		return http.StatusUnauthorized,
			"Path requested is invalid for payments consent"
	}

	submissionData := consentAccessMap(body, "Data")
	if submissionData == nil {
		return http.StatusBadRequest,
			"Invalid Submission payload Data Object found"
	}

	submittedConsentID := consentAccessString(
		submissionData,
		"ConsentId",
	)
	if submittedConsentID == "" ||
		submittedConsentID != resource.ID {
		return http.StatusBadRequest,
			"Invalid consent ID"
	}

	submittedInitiation := consentAccessMap(
		submissionData,
		"Initiation",
	)
	if submittedInitiation == nil {
		return http.StatusBadRequest,
			"Invalid Submission payload Initiation Object found"
	}

	receiptData := consentAccessReceiptData(resource)
	authorisedInitiation := consentAccessMap(
		receiptData,
		"Initiation",
	)
	if authorisedInitiation == nil {
		return http.StatusBadRequest,
			"Authorised consent Initiation is missing"
	}

	// Both objects entered this process through JSON decoding, making
	// DeepEqual equivalent to the semantic JSON-tree comparison used by
	// DefaultConsentValidator for this object structure.
	if !reflect.DeepEqual(
		authorisedInitiation,
		submittedInitiation,
	) {
		return http.StatusBadRequest,
			"Initiation payloads does not match"
	}

	// OBWriteDomestic2 requires the Risk object submitted with
	// the payment to match the Risk object authorised in the
	// corresponding payment consent.
	receipt :=
		req.Data.ConsentResource.Receipt

	if receipt == nil {
		return http.StatusBadRequest,
			"Authorised consent receipt not found"
	}

	authorisedRisk, authorisedRiskOK :=
		receipt["Risk"].(map[string]any)

	if !authorisedRiskOK {
		return http.StatusBadRequest,
			"Authorised Risk object not found"
	}

	submittedRisk, submittedRiskOK :=
		body["Risk"].(map[string]any)

	if !submittedRiskOK {
		return http.StatusBadRequest,
			"Invalid Submission payload Risk Object found"
	}

	if !reflect.DeepEqual(
		authorisedRisk,
		submittedRisk,
	) {
		return http.StatusBadRequest,
			"Risk payloads does not match"
	}

	return 0, ""
}

func validateFundsConsentAccess(
	req consentAccessExtensionRequest,
) (int, string) {
	resource := req.Data.ConsentResource
	path := strings.TrimSpace(
		req.Data.DataRequest.ElectedResource,
	)

	if path != "/funds-confirmations" {
		return http.StatusUnauthorized,
			"Invalid request URI"
	}

	data := consentAccessReceiptData(resource)
	if data == nil {
		return http.StatusBadRequest,
			"Consent receipt Data object is missing"
	}

	// Open-ended CoF authorization remains valid when the authorised
	// receipt intentionally omits ExpirationDateTime. When present,
	// expiration is enforced.
	valid, err := consentAccessExpiration(data, false)
	if err != nil {
		return http.StatusBadRequest,
			"Invalid consent expiration date"
	}
	if !valid {
		return http.StatusUnauthorized,
			"Provided consent is expired"
	}

	bodyData := consentAccessMap(
		req.Data.DataRequest.Body,
		"Data",
	)
	if bodyData == nil {
		return http.StatusBadRequest,
			"Invalid Submission payload Data Object found"
	}

	submittedConsentID := consentAccessString(
		bodyData,
		"ConsentId",
	)
	if submittedConsentID == "" ||
		submittedConsentID != resource.ID {
		return http.StatusBadRequest,
			"Invalid consent ID"
	}

	return 0, ""
}

func (a *API) validateConsentAccess(
	w http.ResponseWriter,
	r *http.Request,
) {
	if r.Method != http.MethodPost {
		errJSON(
			w,
			http.StatusMethodNotAllowed,
			"method not allowed",
		)
		return
	}

	expectedUser := extensionCredential(
		"FS_EXTENSION_USER",
		"fs-extension",
	)
	expectedPass := extensionCredential(
		"FS_EXTENSION_PASSWORD",
		"fs-extension-secret",
	)

	user, pass, ok := r.BasicAuth()
	if !ok || user != expectedUser || pass != expectedPass {
		w.Header().Set(
			"WWW-Authenticate",
			`Basic realm="fs-extension"`,
		)
		errJSON(
			w,
			http.StatusUnauthorized,
			"invalid extension credentials",
		)
		return
	}

	var req consentAccessExtensionRequest

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeConsentAccessError(
			w,
			req.RequestID,
			http.StatusBadRequest,
			"invalid extension request",
		)
		return
	}

	resource := req.Data.ConsentResource
	requestData := req.Data.DataRequest

	consentID := strings.TrimSpace(req.Data.ConsentID)

	if consentID == "" ||
		resource.ID == "" ||
		requestData.ConsentID == "" ||
		consentID != resource.ID ||
		consentID != requestData.ConsentID {
		writeConsentAccessError(
			w,
			req.RequestID,
			http.StatusBadRequest,
			"Consent ID mismatch",
		)
		return
	}

	if resource.ClientID == "" ||
		requestData.ClientID == "" ||
		resource.ClientID != requestData.ClientID {
		writeConsentAccessError(
			w,
			req.RequestID,
			http.StatusForbidden,
			"Invalid Client Id",
		)
		return
	}

	if resource.Receipt == nil {
		writeConsentAccessError(
			w,
			req.RequestID,
			http.StatusBadRequest,
			"Consent Details cannot be found",
		)
		return
	}

	if resource.Status != "Authorised" {
		writeConsentAccessError(
			w,
			req.RequestID,
			http.StatusBadRequest,
			"Consent is not in the correct state",
		)
		return
	}

	var (
		code    int
		message string
	)

	switch strings.ToLower(strings.TrimSpace(resource.Type)) {
	case "accounts":
		code, message = validateAccountConsentAccess(req)

	case "payments":
		code, message = validatePaymentConsentAccess(req)

	case "fundsconfirmations":
		code, message = validateFundsConsentAccess(req)

	default:
		code = http.StatusBadRequest
		message = "Invalid consent type"
	}

	if code != 0 {
		writeConsentAccessError(
			w,
			req.RequestID,
			code,
			message,
		)
		return
	}

	writeConsentAccessSuccess(
		w,
		req.RequestID,
	)
}
