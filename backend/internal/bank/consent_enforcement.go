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
	"net/http"
	"os"
	"strings"
	"sync"
)

type accountRequestHeader struct {
	Alg string `json:"alg"`
}

type accountRequestAuthorization struct {
	AuthorizationID     string `json:"authorizationId"`
	AuthorizationStatus string `json:"authorizationStatus"`
}

type accountRequestMapping struct {
	MappingStatus   string `json:"mappingStatus"`
	AccountID       string `json:"account_id"`
	AuthorizationID string `json:"authorizationId"`
	Permission      string `json:"permission"`
}

type accountRequestClaims struct {
	ClientID                string                        `json:"clientId"`
	CurrentStatus           string                        `json:"currentStatus"`
	ConsentType             string                        `json:"consent_type"`
	ConsentID               string                        `json:"consentId"`
	AuthorizationResources  []accountRequestAuthorization `json:"authorizationResources"`
	ConsentMappingResources []accountRequestMapping       `json:"consentMappingResources"`
}

var (
	accountRequestKeyOnce sync.Once
	accountRequestKey     *rsa.PublicKey
	accountRequestKeyErr  error
)

func loadAccountRequestPublicKey() (*rsa.PublicKey, error) {
	accountRequestKeyOnce.Do(func() {
		path := strings.TrimSpace(os.Getenv("FS_ARI_CERT_FILE"))
		if path == "" {
			path = "/run/secrets/wso2is.crt"
		}

		raw, err := os.ReadFile(path)
		if err != nil {
			accountRequestKeyErr = fmt.Errorf("read IS certificate: %w", err)
			return
		}

		block, _ := pem.Decode(raw)
		if block == nil || block.Type != "CERTIFICATE" {
			accountRequestKeyErr = errors.New("IS certificate is not valid PEM")
			return
		}

		cert, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			accountRequestKeyErr = fmt.Errorf("parse IS certificate: %w", err)
			return
		}

		key, ok := cert.PublicKey.(*rsa.PublicKey)
		if !ok {
			accountRequestKeyErr = errors.New("IS certificate does not contain an RSA public key")
			return
		}

		accountRequestKey = key
	})

	return accountRequestKey, accountRequestKeyErr
}

func decodeJWTSegment(segment string) ([]byte, error) {
	return base64.RawURLEncoding.DecodeString(segment)
}

func verifyAccountRequestInformation(token string) (*accountRequestClaims, error) {
	token = strings.TrimSpace(token)
	if token == "" {
		return nil, errors.New("Account-Request-Information header is missing")
	}

	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, errors.New("Account-Request-Information is not a compact JWS")
	}

	headerBytes, err := decodeJWTSegment(parts[0])
	if err != nil {
		return nil, fmt.Errorf("decode JWS header: %w", err)
	}

	var header accountRequestHeader
	if err := json.Unmarshal(headerBytes, &header); err != nil {
		return nil, fmt.Errorf("parse JWS header: %w", err)
	}

	if header.Alg != "RS256" {
		return nil, fmt.Errorf("unexpected JWS algorithm %q", header.Alg)
	}

	signature, err := decodeJWTSegment(parts[2])
	if err != nil {
		return nil, fmt.Errorf("decode JWS signature: %w", err)
	}

	publicKey, err := loadAccountRequestPublicKey()
	if err != nil {
		return nil, err
	}

	signingInput := parts[0] + "." + parts[1]
	digest := sha256.Sum256([]byte(signingInput))

	if err := rsa.VerifyPKCS1v15(
		publicKey,
		crypto.SHA256,
		digest[:],
		signature,
	); err != nil {
		return nil, errors.New("Account-Request-Information signature verification failed")
	}

	payloadBytes, err := decodeJWTSegment(parts[1])
	if err != nil {
		return nil, fmt.Errorf("decode JWS payload: %w", err)
	}

	var claims accountRequestClaims
	if err := json.Unmarshal(payloadBytes, &claims); err != nil {
		return nil, fmt.Errorf("parse JWS payload: %w", err)
	}

	if claims.CurrentStatus != "Authorised" {
		return nil, fmt.Errorf("consent status is %q", claims.CurrentStatus)
	}

	if claims.ConsentType != "accounts" {
		return nil, fmt.Errorf("unexpected consent type %q", claims.ConsentType)
	}

	return &claims, nil
}

func allowedAccountsFromRequest(r *http.Request) (map[string]struct{}, error) {
	claims, err := verifyAccountRequestInformation(
		r.Header.Get("Account-Request-Information"),
	)
	if err != nil {
		return nil, err
	}

	authorised := make(map[string]struct{})

	for _, resource := range claims.AuthorizationResources {
		if resource.AuthorizationStatus == "Authorised" &&
			resource.AuthorizationID != "" {
			authorised[resource.AuthorizationID] = struct{}{}
		}
	}

	if len(authorised) == 0 {
		return nil, errors.New("consent contains no authorised authorization resource")
	}

	allowed := make(map[string]struct{})

	for _, mapping := range claims.ConsentMappingResources {
		if mapping.MappingStatus != "active" ||
			mapping.Permission != "primary" ||
			mapping.AccountID == "" {
			continue
		}

		if _, ok := authorised[mapping.AuthorizationID]; !ok {
			continue
		}

		allowed[mapping.AccountID] = struct{}{}
	}

	if len(allowed) == 0 {
		return nil, errors.New("consent contains no active account mappings")
	}

	return allowed, nil
}
