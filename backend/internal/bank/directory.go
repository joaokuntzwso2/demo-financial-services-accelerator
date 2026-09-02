package bank

import (
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"math/big"
	"net/http"
	"os"
)

const (
	defaultDirectoryCertFile = "/run/secrets/directory.crt"
	defaultTPPPublicCertFile = "/run/secrets/tpp.crt"
)

func directoryJWKS(w http.ResponseWriter, r *http.Request) {
	servePublicJWKS(
		w,
		r,
		directoryEnvOrDefault("DIRECTORY_CERT_FILE", defaultDirectoryCertFile),
	)
}

func softwareJWKS(w http.ResponseWriter, r *http.Request) {
	servePublicJWKS(
		w,
		r,
		directoryEnvOrDefault("TPP_PUBLIC_CERT_FILE", defaultTPPPublicCertFile),
	)
}

func servePublicJWKS(w http.ResponseWriter, _ *http.Request, certFile string) {
	jwk, err := publicJWKFromCertificateFile(certFile)
	if err != nil {
		errJSON(w, http.StatusInternalServerError, err.Error())
		return
	}

	write(w, http.StatusOK, map[string]any{
		"keys": []any{jwk},
	})
}

func publicJWKFromCertificateFile(certFile string) (map[string]any, error) {
	raw, err := os.ReadFile(certFile)
	if err != nil {
		return nil, err
	}

	block, _ := pem.Decode(raw)
	if block == nil {
		return nil, errors.New("certificate is not PEM")
	}

	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil, err
	}

	pub, ok := cert.PublicKey.(*rsa.PublicKey)
	if !ok {
		return nil, errors.New("certificate public key is not RSA")
	}

	kid := certificateKID(cert)

	return map[string]any{
		"kty": "RSA",
		"use": "sig",
		"alg": "PS256",
		"kid": kid,
		"n":   base64.RawURLEncoding.EncodeToString(pub.N.Bytes()),
		"e":   base64.RawURLEncoding.EncodeToString(big.NewInt(int64(pub.E)).Bytes()),
		"x5c": []string{
			base64.StdEncoding.EncodeToString(cert.Raw),
		},
	}, nil
}

func certificateKID(cert *x509.Certificate) string {
	sum := sha256.Sum256(cert.Raw)
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

func directoryEnvOrDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
