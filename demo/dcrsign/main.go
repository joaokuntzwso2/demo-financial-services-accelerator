package main

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"math/big"
	"os"
	"strings"
)

func main() {
	if len(os.Args) < 2 {
		fatal("usage: dcrsign <sign|kid|jwk|decode> ...")
	}

	switch os.Args[1] {
	case "sign":
		signCommand(os.Args[2:])
	case "kid":
		kidCommand(os.Args[2:])
	case "jwk":
		jwkCommand(os.Args[2:])
	case "decode":
		decodeCommand(os.Args[2:])
	default:
		fatal("unknown command: " + os.Args[1])
	}
}

func signCommand(args []string) {
	fs := flag.NewFlagSet("sign", flag.ExitOnError)
	keyPath := fs.String("key", "", "RSA PEM private key")
	certPath := fs.String("cert", "", "PEM certificate used to derive kid")
	payloadPath := fs.String("payload", "", "JSON payload file")
	_ = fs.Parse(args)

	if *keyPath == "" || *certPath == "" || *payloadPath == "" {
		fatal("sign requires --key, --cert and --payload")
	}

	key, err := readRSAKey(*keyPath)
	if err != nil {
		fatal(err.Error())
	}
	cert, err := readCertificate(*certPath)
	if err != nil {
		fatal(err.Error())
	}

	payload, err := os.ReadFile(*payloadPath)
	if err != nil {
		fatal(err.Error())
	}

	var parsed any
	if err := json.Unmarshal(payload, &parsed); err != nil {
		fatal("payload is not valid JSON: " + err.Error())
	}

	token, err := signPS256(key, certificateKID(cert), payload)
	if err != nil {
		fatal(err.Error())
	}
	fmt.Print(token)
}

func kidCommand(args []string) {
	fs := flag.NewFlagSet("kid", flag.ExitOnError)
	certPath := fs.String("cert", "", "PEM certificate")
	_ = fs.Parse(args)
	if *certPath == "" {
		fatal("kid requires --cert")
	}
	cert, err := readCertificate(*certPath)
	if err != nil {
		fatal(err.Error())
	}
	fmt.Print(certificateKID(cert))
}

func jwkCommand(args []string) {
	fs := flag.NewFlagSet("jwk", flag.ExitOnError)
	certPath := fs.String("cert", "", "PEM certificate")
	_ = fs.Parse(args)
	if *certPath == "" {
		fatal("jwk requires --cert")
	}
	cert, err := readCertificate(*certPath)
	if err != nil {
		fatal(err.Error())
	}
	jwk, err := publicJWK(cert)
	if err != nil {
		fatal(err.Error())
	}
	raw, _ := json.MarshalIndent(jwk, "", "  ")
	fmt.Println(string(raw))
}

func decodeCommand(args []string) {
	fs := flag.NewFlagSet("decode", flag.ExitOnError)
	token := fs.String("jwt", "", "compact JWT")
	_ = fs.Parse(args)
	if *token == "" {
		fatal("decode requires --jwt")
	}
	parts := strings.Split(*token, ".")
	if len(parts) != 3 {
		fatal("invalid compact JWT")
	}

	header, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		fatal(err.Error())
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		fatal(err.Error())
	}

	var h, p any
	if err := json.Unmarshal(header, &h); err != nil {
		fatal(err.Error())
	}
	if err := json.Unmarshal(payload, &p); err != nil {
		fatal(err.Error())
	}

	raw, _ := json.MarshalIndent(
		map[string]any{"header": h, "payload": p},
		"",
		"  ",
	)
	fmt.Println(string(raw))
}

func signPS256(
	key *rsa.PrivateKey,
	kid string,
	payload []byte,
) (string, error) {
	header, _ := json.Marshal(map[string]any{
		"alg": "PS256",
		"kid": kid,
		"typ": "JWT",
	})

	headerPart := base64.RawURLEncoding.EncodeToString(header)
	payloadPart := base64.RawURLEncoding.EncodeToString(payload)
	input := headerPart + "." + payloadPart

	sum := sha256.Sum256([]byte(input))
	sig, err := rsa.SignPSS(
		rand.Reader,
		key,
		crypto.SHA256,
		sum[:],
		&rsa.PSSOptions{
			SaltLength: rsa.PSSSaltLengthEqualsHash,
			Hash:       crypto.SHA256,
		},
	)
	if err != nil {
		return "", err
	}

	return input + "." +
		base64.RawURLEncoding.EncodeToString(sig), nil
}

func readRSAKey(path string) (*rsa.PrivateKey, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	block, _ := pem.Decode(raw)
	if block == nil {
		return nil, errors.New("private key is not PEM")
	}

	if key, err := x509.ParsePKCS1PrivateKey(block.Bytes); err == nil {
		return key, nil
	}

	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}

	key, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return nil, errors.New("private key is not RSA")
	}
	return key, nil
}

func readCertificate(path string) (*x509.Certificate, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	block, _ := pem.Decode(raw)
	if block == nil {
		return nil, errors.New("certificate is not PEM")
	}

	return x509.ParseCertificate(block.Bytes)
}

func certificateKID(cert *x509.Certificate) string {
	sum := sha256.Sum256(cert.Raw)
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

func publicJWK(cert *x509.Certificate) (map[string]any, error) {
	pub, ok := cert.PublicKey.(*rsa.PublicKey)
	if !ok {
		return nil, errors.New("certificate public key is not RSA")
	}

	return map[string]any{
		"kty": "RSA",
		"use": "sig",
		"alg": "PS256",
		"kid": certificateKID(cert),
		"n":   base64.RawURLEncoding.EncodeToString(pub.N.Bytes()),
		"e":   base64.RawURLEncoding.EncodeToString(big.NewInt(int64(pub.E)).Bytes()),
	}, nil
}

func fatal(message string) {
	fmt.Fprintln(os.Stderr, "ERROR:", message)
	os.Exit(1)
}
