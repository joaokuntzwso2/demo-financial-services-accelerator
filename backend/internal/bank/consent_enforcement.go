package bank

import (
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

const accountRequestInformationHeader = "Account-Request-Information"

var (
	errInvalidConsentContext = errors.New(
		"invalid consent context",
	)

	errConsentTermsMismatch = errors.New(
		"request is outside authorised consent terms",
	)

	// Keep these names because the existing unit tests reset this cache after
	// installing a temporary IS signing certificate.
	accountRequestKeyOnce sync.Once
	accountRequestKey     *rsa.PublicKey
	accountRequestKeyErr  error
)

type verifiedConsentContext struct {
	ClientID    string
	ConsentID   string
	ConsentType string
	Status      string

	Receipt map[string]any
	Payload map[string]any
}

func loadAccountRequestPublicKey() (*rsa.PublicKey, error) {
	accountRequestKeyOnce.Do(func() {
		path := strings.TrimSpace(
			os.Getenv("FS_ARI_CERT_FILE"),
		)

		if path == "" {
			path = "/run/secrets/wso2is.crt"
		}

		b, err := os.ReadFile(path)
		if err != nil {
			accountRequestKeyErr = fmt.Errorf(
				"read IS certificate: %w",
				err,
			)
			return
		}

		block, _ := pem.Decode(b)

		if block == nil || block.Type != "CERTIFICATE" {
			accountRequestKeyErr = errors.New(
				"IS certificate is not a PEM CERTIFICATE",
			)
			return
		}

		cert, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			accountRequestKeyErr = fmt.Errorf(
				"parse IS certificate: %w",
				err,
			)
			return
		}

		key, ok := cert.PublicKey.(*rsa.PublicKey)
		if !ok {
			accountRequestKeyErr = errors.New(
				"IS certificate public key is not RSA",
			)
			return
		}

		accountRequestKey = key
	})

	return accountRequestKey, accountRequestKeyErr
}

func verifySignedConsentContext(
	compact string,
) (map[string]any, error) {
	parts := strings.Split(compact, ".")

	if len(parts) != 3 {
		return nil, fmt.Errorf(
			"%w: malformed JWS",
			errInvalidConsentContext,
		)
	}

	headerJSON, err := base64.RawURLEncoding.DecodeString(
		parts[0],
	)
	if err != nil {
		return nil, fmt.Errorf(
			"%w: invalid JWS header",
			errInvalidConsentContext,
		)
	}

	payloadJSON, err := base64.RawURLEncoding.DecodeString(
		parts[1],
	)
	if err != nil {
		return nil, fmt.Errorf(
			"%w: invalid JWS payload",
			errInvalidConsentContext,
		)
	}

	signature, err := base64.RawURLEncoding.DecodeString(
		parts[2],
	)
	if err != nil {
		return nil, fmt.Errorf(
			"%w: invalid JWS signature encoding",
			errInvalidConsentContext,
		)
	}

	var header map[string]any

	if err := json.Unmarshal(headerJSON, &header); err != nil {
		return nil, fmt.Errorf(
			"%w: invalid JWS header JSON",
			errInvalidConsentContext,
		)
	}

	// WSO2 FS signs Account-Request-Information with the IS primary
	// RSA key using RS256 in this demo.
	if stringValue(header, "alg") != "RS256" {
		return nil, fmt.Errorf(
			"%w: unsupported JWS algorithm",
			errInvalidConsentContext,
		)
	}

	key, err := loadAccountRequestPublicKey()
	if err != nil {
		return nil, fmt.Errorf(
			"%w: %v",
			errInvalidConsentContext,
			err,
		)
	}

	signingInput := parts[0] + "." + parts[1]
	digest := sha256.Sum256([]byte(signingInput))

	if err := rsa.VerifyPKCS1v15(
		key,
		crypto.SHA256,
		digest[:],
		signature,
	); err != nil {
		return nil, fmt.Errorf(
			"%w: JWS signature verification failed",
			errInvalidConsentContext,
		)
	}

	var payload map[string]any

	if err := json.Unmarshal(payloadJSON, &payload); err != nil {
		return nil, fmt.Errorf(
			"%w: invalid JWS payload JSON",
			errInvalidConsentContext,
		)
	}

	return payload, nil
}

func consentContextFromRequest(
	r *http.Request,
	expectedType string,
) (*verifiedConsentContext, error) {
	compact := strings.TrimSpace(
		r.Header.Get(accountRequestInformationHeader),
	)

	if compact == "" {
		return nil, fmt.Errorf(
			"%w: missing %s",
			errInvalidConsentContext,
			accountRequestInformationHeader,
		)
	}

	payload, err := verifySignedConsentContext(compact)
	if err != nil {
		return nil, err
	}

	ctx := &verifiedConsentContext{
		ClientID: strings.TrimSpace(
			stringValue(payload, "clientId"),
		),
		ConsentID: strings.TrimSpace(
			stringValue(payload, "consentId"),
		),
		ConsentType: strings.ToLower(
			strings.TrimSpace(
				stringValue(payload, "consent_type"),
			),
		),
		Status: strings.TrimSpace(
			stringValue(payload, "currentStatus"),
		),
		Payload: payload,
	}

	ctx.Receipt, _ = payload["receipt"].(map[string]any)

	if ctx.ConsentID == "" {
		return nil, fmt.Errorf(
			"%w: consentId missing",
			errInvalidConsentContext,
		)
	}

	if ctx.Status != "Authorised" {
		return nil, fmt.Errorf(
			"%w: consent is not Authorised",
			errInvalidConsentContext,
		)
	}

	if ctx.ConsentType != expectedType {
		return nil, fmt.Errorf(
			"%w: expected consent type %q, got %q",
			errInvalidConsentContext,
			expectedType,
			ctx.ConsentType,
		)
	}

	if ctx.Receipt == nil {
		return nil, fmt.Errorf(
			"%w: signed consent receipt missing",
			errInvalidConsentContext,
		)
	}

	expired, err := consentExpired(ctx)
	if err != nil {
		return nil, fmt.Errorf(
			"%w: invalid consent expiry",
			errInvalidConsentContext,
		)
	}

	if expired {
		return nil, fmt.Errorf(
			"%w: consent expired",
			errInvalidConsentContext,
		)
	}

	return ctx, nil
}

func accountConsentFromRequest(
	r *http.Request,
) (
	*verifiedConsentContext,
	map[string]struct{},
	error,
) {
	ctx, err := consentContextFromRequest(r, "accounts")
	if err != nil {
		return nil, nil, err
	}

	authorised := map[string]struct{}{}

	for _, resource := range sliceObjects(
		ctx.Payload["authorizationResources"],
	) {
		if stringValue(
			resource,
			"authorizationStatus",
		) != "Authorised" {
			continue
		}

		id := stringValue(
			resource,
			"authorizationId",
		)

		if id != "" {
			authorised[id] = struct{}{}
		}
	}

	allowed := map[string]struct{}{}

	for _, mapping := range sliceObjects(
		ctx.Payload["consentMappingResources"],
	) {
		authorizationID := stringValue(
			mapping,
			"authorizationId",
		)

		if _, ok := authorised[authorizationID]; !ok {
			continue
		}

		if !strings.EqualFold(
			stringValue(mapping, "mappingStatus"),
			"active",
		) {
			continue
		}

		if !strings.EqualFold(
			stringValue(mapping, "permission"),
			"primary",
		) {
			continue
		}

		accountID := firstString(
			mapping,
			"account_id",
			"accountId",
			"AccountId",
		)

		if accountID != "" {
			allowed[accountID] = struct{}{}
		}
	}

	if len(allowed) == 0 {
		return nil, nil, fmt.Errorf(
			"%w: no active account mappings",
			errInvalidConsentContext,
		)
	}

	return ctx, allowed, nil
}

// Compatibility wrapper used by the original Accounts implementation/tests.
func allowedAccountsFromRequest(
	r *http.Request,
) (map[string]struct{}, error) {
	_, allowed, err := accountConsentFromRequest(r)

	return allowed, err
}

func consentPermissions(
	ctx *verifiedConsentContext,
) map[string]struct{} {
	out := map[string]struct{}{}

	data := receiptDataMap(ctx.Receipt)
	if data == nil {
		return out
	}

	switch values := data["Permissions"].(type) {
	case []any:
		for _, value := range values {
			s, ok := value.(string)
			if !ok {
				continue
			}

			s = strings.TrimSpace(s)
			if s != "" {
				out[s] = struct{}{}
			}
		}

	case []string:
		for _, value := range values {
			value = strings.TrimSpace(value)

			if value != "" {
				out[value] = struct{}{}
			}
		}
	}

	return out
}

func hasAnyConsentPermission(
	ctx *verifiedConsentContext,
	names ...string,
) bool {
	permissions := consentPermissions(ctx)

	for _, name := range names {
		if _, ok := permissions[name]; ok {
			return true
		}
	}

	return false
}

func transactionWithinConsentWindow(
	ctx *verifiedConsentContext,
	tx Transaction,
) bool {
	data := receiptDataMap(ctx.Receipt)
	if data == nil {
		return false
	}

	txTime, err := time.Parse(
		time.RFC3339,
		tx.BookingDateTime,
	)
	if err != nil {
		return false
	}

	if value := stringValue(
		data,
		"TransactionFromDateTime",
	); value != "" {
		from, err := time.Parse(time.RFC3339, value)

		if err != nil || txTime.Before(from) {
			return false
		}
	}

	if value := stringValue(
		data,
		"TransactionToDateTime",
	); value != "" {
		to, err := time.Parse(time.RFC3339, value)

		if err != nil || txTime.After(to) {
			return false
		}
	}

	return true
}

func authorizePaymentRequest(
	ctx *verifiedConsentContext,
	request PaymentRequest,
) error {
	if request.ConsentID == "" ||
		request.ConsentID != ctx.ConsentID {
		return fmt.Errorf(
			"%w: ConsentId differs",
			errConsentTermsMismatch,
		)
	}

	data := receiptDataMap(ctx.Receipt)

	initiation, _ := objectValue(
		data,
		"Initiation",
	)

	if initiation == nil {
		return fmt.Errorf(
			"%w: payment Initiation missing",
			errInvalidConsentContext,
		)
	}

	if !optionalExact(
		initiation,
		"InstructionIdentification",
		request.InstructionIdentification,
	) {
		return fmt.Errorf(
			"%w: InstructionIdentification differs",
			errConsentTermsMismatch,
		)
	}

	if !optionalExact(
		initiation,
		"EndToEndIdentification",
		request.EndToEndIdentification,
	) {
		return fmt.Errorf(
			"%w: EndToEndIdentification differs",
			errConsentTermsMismatch,
		)
	}

	debtor, _ := objectValue(
		initiation,
		"DebtorAccount",
	)

	creditor, _ := objectValue(
		initiation,
		"CreditorAccount",
	)

	if debtor == nil || creditor == nil {
		return fmt.Errorf(
			"%w: debtor or creditor consent terms missing",
			errInvalidConsentContext,
		)
	}

	if stringValue(
		debtor,
		"Identification",
	) != request.DebtorAccount {
		return fmt.Errorf(
			"%w: debtor account differs",
			errConsentTermsMismatch,
		)
	}

	if stringValue(
		creditor,
		"Identification",
	) != request.CreditorAccount {
		return fmt.Errorf(
			"%w: creditor account differs",
			errConsentTermsMismatch,
		)
	}

	if expected := stringValue(
		creditor,
		"Name",
	); expected != "" &&
		expected != request.CreditorName {
		return fmt.Errorf(
			"%w: creditor name differs",
			errConsentTermsMismatch,
		)
	}

	amount, _ := objectValue(
		initiation,
		"InstructedAmount",
	)

	if amount == nil {
		return fmt.Errorf(
			"%w: instructed amount missing",
			errInvalidConsentContext,
		)
	}

	if !amountEqual(
		stringValue(amount, "Amount"),
		request.InstructedAmount.Amount,
	) {
		return fmt.Errorf(
			"%w: payment amount differs",
			errConsentTermsMismatch,
		)
	}

	if !strings.EqualFold(
		stringValue(amount, "Currency"),
		request.InstructedAmount.Currency,
	) {
		return fmt.Errorf(
			"%w: payment currency differs",
			errConsentTermsMismatch,
		)
	}

	// UK-style payment consent payloads may carry the transaction reference
	// under RemittanceInformation. It is enforced when present but is not
	// invented when a particular profile omits it.
	if remittance, _ := objectValue(
		initiation,
		"RemittanceInformation",
	); remittance != nil {
		expected := firstString(
			remittance,
			"Reference",
			"Unstructured",
		)

		if expected != "" &&
			expected != request.Reference {
			return fmt.Errorf(
				"%w: payment reference differs",
				errConsentTermsMismatch,
			)
		}
	}

	return nil
}

func authorizeFundsRequest(
	ctx *verifiedConsentContext,
	request FundsRequest,
) (string, error) {
	data := receiptDataMap(ctx.Receipt)

	if data == nil {
		return "", fmt.Errorf(
			"%w: funds consent Data missing",
			errInvalidConsentContext,
		)
	}

	debtor, _ := objectValue(
		data,
		"DebtorAccount",
	)

	if debtor == nil {
		return "", fmt.Errorf(
			"%w: DebtorAccount missing",
			errInvalidConsentContext,
		)
	}

	debtorIdentification := stringValue(
		debtor,
		"Identification",
	)

	if debtorIdentification == "" {
		return "", fmt.Errorf(
			"%w: debtor account identification missing",
			errInvalidConsentContext,
		)
	}

	// The standards-facing protected-resource request contains
	// Data.ConsentId. Bind it again here as defense in depth even
	// though the Financial Services validator has already checked it.
	if request.ConsentID != "" &&
		request.ConsentID != ctx.ConsentID {
		return "", fmt.Errorf(
			"%w: consent ID differs",
			errConsentTermsMismatch,
		)
	}

	// Legacy flat requests carried AccountId. They are retained only
	// for direct/internal test compatibility and must never be able to
	// select a different account from the signed consent.
	if request.AccountID != "" &&
		request.AccountID != debtorIdentification {
		return "", fmt.Errorf(
			"%w: account differs",
			errConsentTermsMismatch,
		)
	}

	// Some CoF profiles bind only the debtor account; others may also
	// carry amount/currency constraints. Enforce them whenever present.
	if amount, _ := objectValue(
		data,
		"InstructedAmount",
	); amount != nil {
		if expected := stringValue(
			amount,
			"Amount",
		); expected != "" &&
			!amountEqual(
				expected,
				request.InstructedAmount.Amount,
			) {
			return "", fmt.Errorf(
				"%w: funds amount differs",
				errConsentTermsMismatch,
			)
		}

		if expected := stringValue(
			amount,
			"Currency",
		); expected != "" &&
			!strings.EqualFold(
				expected,
				request.InstructedAmount.Currency,
			) {
			return "", fmt.Errorf(
				"%w: funds currency differs",
				errConsentTermsMismatch,
			)
		}
	}

	return debtorIdentification, nil
}

func consentExpired(
	ctx *verifiedConsentContext,
) (bool, error) {
	data := receiptDataMap(ctx.Receipt)
	if data == nil {
		return false, nil
	}

	value := strings.TrimSpace(
		stringValue(
			data,
			"ExpirationDateTime",
		),
	)

	// Open-ended CoF consent is a valid model.
	if value == "" {
		return false, nil
	}

	expiry, err := time.Parse(
		time.RFC3339,
		value,
	)
	if err != nil {
		return false, err
	}

	return !time.Now().UTC().Before(expiry), nil
}

func consentHTTPStatus(err error) int {
	if errors.Is(
		err,
		errConsentTermsMismatch,
	) {
		return http.StatusForbidden
	}

	return http.StatusUnauthorized
}

func receiptDataMap(
	receipt map[string]any,
) map[string]any {
	if receipt == nil {
		return nil
	}

	data, _ := receipt["Data"].(map[string]any)

	return data
}

func objectValue(
	m map[string]any,
	key string,
) (map[string]any, bool) {
	if m == nil {
		return nil, false
	}

	value, ok := m[key].(map[string]any)

	return value, ok
}

func stringValue(
	m map[string]any,
	key string,
) string {
	if m == nil {
		return ""
	}

	value, _ := m[key].(string)

	return strings.TrimSpace(value)
}

func firstString(
	m map[string]any,
	keys ...string,
) string {
	for _, key := range keys {
		if value := stringValue(
			m,
			key,
		); value != "" {
			return value
		}
	}

	return ""
}

func optionalExact(
	m map[string]any,
	key string,
	actual string,
) bool {
	expected := stringValue(m, key)

	return expected == "" || expected == actual
}

func sliceObjects(
	value any,
) []map[string]any {
	raw, _ := value.([]any)

	out := make(
		[]map[string]any,
		0,
		len(raw),
	)

	for _, item := range raw {
		m, ok := item.(map[string]any)

		if ok {
			out = append(out, m)
		}
	}

	return out
}

func amountEqual(
	left string,
	right string,
) bool {
	l, lok := new(big.Rat).SetString(
		strings.TrimSpace(left),
	)

	r, rok := new(big.Rat).SetString(
		strings.TrimSpace(right),
	)

	return lok &&
		rok &&
		l.Cmp(r) == 0
}

func accountMatchesIdentification(
	account Account,
	identification string,
) bool {
	identification = strings.TrimSpace(identification)

	if identification == "" {
		return false
	}

	return account.AccountID == identification ||
		account.Identification == identification
}
