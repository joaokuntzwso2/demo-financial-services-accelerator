package main

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"html/template"
	"io"
	"log"
	"math/big"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// FinLink is deliberately a local demo TPP client. It keeps browser/user
// authorization real and delegates consent/authentication to WSO2.
type Config struct {
	Root        string
	ListenAddr  string
	PortalURL   string
	RedirectURI string
	IS          string
	Gateway     string
	Bank        string
	ClientID    string
	CertPath    string
	KeyPath     string
	CAPath      string
	KID         string
}

type SecurityProof struct {
	PAR                  bool   `json:"par"`
	PKCE                 bool   `json:"pkce"`
	SignedRequestObject  bool   `json:"signed_request_object"`
	MTLS                 bool   `json:"mtls"`
	ConsentID            bool   `json:"consent_id"`
	IDTokenSignature     bool   `json:"id_token_signature"`
	AccessTokenSignature bool   `json:"access_token_signature"`
	CertificateBound     bool   `json:"certificate_bound"`
	Detail               string `json:"detail,omitempty"`
}

type DomainState struct {
	Domain         string        `json:"domain"`
	ConsentID      string        `json:"consent_id,omitempty"`
	ConsentStatus  string        `json:"consent_status,omitempty"`
	Expires        string        `json:"expires,omitempty"`
	Permissions    []string      `json:"permissions,omitempty"`
	Authorized     bool          `json:"authorized"`
	AccessToken    string        `json:"-"`
	TokenExpiry    time.Time     `json:"-"`
	AccountIDs     []string      `json:"account_ids,omitempty"`
	PaymentID      string        `json:"payment_id,omitempty"`
	PaymentIdemKey string        `json:"-"`
	LastResult     any           `json:"last_result,omitempty"`
	LastHTTP       int           `json:"last_http,omitempty"`
	Security       SecurityProof `json:"security"`
}

type AuthSession struct {
	Domain     string
	ConsentID  string
	State      string
	Nonce      string
	Verifier   string
	Scope      string
	CreatedAt  time.Time
	RequestURI string
}

type AppToken struct {
	Token  string
	Expiry time.Time
}

type Portal struct {
	cfg        Config
	mu         sync.RWMutex
	domains    map[string]*DomainState
	pending    map[string]*AuthSession
	appTokens  map[string]AppToken
	mtlsClient *http.Client
	httpClient *http.Client
	jwks       map[string]*rsa.PublicKey
	jwksAt     time.Time
	tmpl       *template.Template
}

type stateFile struct {
	Application struct {
		ConsumerKey string `json:"consumerKey"`
	} `json:"application"`
}

type startResponse struct {
	Domain        string `json:"domain"`
	ConsentID     string `json:"consent_id"`
	ConsentStatus string `json:"consent_status"`
	AuthURL       string `json:"auth_url"`
	Username      string `json:"username"`
	Password      string `json:"password"`
	State         string `json:"state"`
}

type actionRequest struct {
	Domain    string `json:"domain"`
	Action    string `json:"action"`
	AccountID string `json:"account_id,omitempty"`
	Amount    string `json:"amount,omitempty"`
	Currency  string `json:"currency,omitempty"`
}

type actionResponse struct {
	HTTP int `json:"http"`
	Data any `json:"data"`
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		log.Fatal(err)
	}

	p, err := newPortal(cfg)
	if err != nil {
		log.Fatal(err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", p.handleIndex)
	mux.HandleFunc("/healthz", p.handleHealth)
	mux.HandleFunc("/api/state", p.handleState)
	mux.HandleFunc("/api/start", p.handleStart)
	mux.HandleFunc("/api/action", p.handleAction)
	mux.HandleFunc("/api/negative-tests", p.handleNegativeTests)
	mux.HandleFunc("/api/consent-lifecycle/accounts", p.handleAccountsConsentLifecycle)
	mux.HandleFunc("/api/consent-lifecycle/accounts/retest", p.handleAccountsConsentRetest)
	mux.HandleFunc("/api/reset", p.handleReset)
	mux.HandleFunc("/callback", p.handleCallback)
	mux.HandleFunc("/callback/fragment", p.handleCallbackFragment)

	server := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           securityHeaders(mux),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	log.Printf("FinLink Demo Portal: %s", cfg.PortalURL)
	log.Printf("OAuth callback: %s", cfg.RedirectURI)
	log.Printf("TPP client id: %s", cfg.ClientID)
	log.Printf("Protected calls: FinLink -> APIM Gateway -> WSO2 FS -> Bank")

	if err := server.ListenAndServeTLS(cfg.CertPath, cfg.KeyPath); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func loadConfig() (Config, error) {
	root, err := os.Getwd()
	if err != nil {
		return Config{}, err
	}

	statePath := filepath.Join(root, ".state", "demo-access", "demo-access.json")
	b, err := os.ReadFile(statePath)
	if err != nil {
		return Config{}, fmt.Errorf("read %s: %w", statePath, err)
	}

	var st stateFile
	if err := json.Unmarshal(b, &st); err != nil {
		return Config{}, fmt.Errorf("parse %s: %w", statePath, err)
	}
	if strings.TrimSpace(st.Application.ConsumerKey) == "" {
		return Config{}, fmt.Errorf("application.consumerKey missing in %s", statePath)
	}

	certDir := filepath.Join(root, ".state", "certs")
	kidBytes, err := os.ReadFile(filepath.Join(certDir, "tpp.kid"))
	if err != nil {
		return Config{}, err
	}

	cfg := Config{
		Root:        root,
		ListenAddr:  env("FINLINK_LISTEN_ADDR", "127.0.0.1:9445"),
		PortalURL:   env("FINLINK_PORTAL_URL", "https://localhost:9445"),
		RedirectURI: env("FINLINK_REDIRECT_URI", "https://localhost:9445/callback"),
		IS:          env("IS_PUBLIC_URL", "https://localhost:9446"),
		Gateway:     env("GW_PUBLIC_URL", "https://localhost:8243"),
		Bank:        env("BANK_PUBLIC_URL", "http://localhost:8080"),
		ClientID:    st.Application.ConsumerKey,
		CertPath:    filepath.Join(certDir, "tpp.crt"),
		KeyPath:     filepath.Join(certDir, "tpp.key"),
		CAPath:      filepath.Join(certDir, "ca.crt"),
		KID:         strings.TrimSpace(string(kidBytes)),
	}

	for _, file := range []string{cfg.CertPath, cfg.KeyPath, cfg.CAPath} {
		if info, err := os.Stat(file); err != nil || info.Size() == 0 {
			return Config{}, fmt.Errorf("required PKI file missing: %s", file)
		}
	}

	return cfg, nil
}

func env(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}

func newPortal(cfg Config) (*Portal, error) {
	cert, err := tls.LoadX509KeyPair(cfg.CertPath, cfg.KeyPath)
	if err != nil {
		return nil, fmt.Errorf("load TPP keypair: %w", err)
	}

	caPEM, err := os.ReadFile(cfg.CAPath)
	if err != nil {
		return nil, err
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(caPEM) {
		return nil, errors.New("could not load demo CA")
	}

	baseTLS := &tls.Config{
		MinVersion: tls.VersionTLS12,
		RootCAs:    roots,
	}
	mtlsTLS := baseTLS.Clone()
	mtlsTLS.Certificates = []tls.Certificate{cert}

	p := &Portal{
		cfg: cfg,
		domains: map[string]*DomainState{
			"accounts": {Domain: "accounts"},
			"payments": {Domain: "payments"},
			"cof":      {Domain: "cof"},
		},
		pending:   map[string]*AuthSession{},
		appTokens: map[string]AppToken{},
		mtlsClient: &http.Client{
			Timeout:   30 * time.Second,
			Transport: &http.Transport{TLSClientConfig: mtlsTLS},
		},
		httpClient: &http.Client{
			Timeout:   30 * time.Second,
			Transport: &http.Transport{TLSClientConfig: baseTLS},
		},
		jwks: map[string]*rsa.PublicKey{},
	}

	p.tmpl, err = template.ParseFiles(filepath.Join(cfg.Root, "demo", "finlink", "templates", "index.html"))
	if err != nil {
		return nil, err
	}
	return p, nil
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Pragma", "no-cache")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'")
		next.ServeHTTP(w, r)
	})
}

func (p *Portal) handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	data := map[string]string{
		"ClientID":  p.cfg.ClientID,
		"PortalURL": p.cfg.PortalURL,
	}
	if err := p.tmpl.Execute(w, data); err != nil {
		log.Printf("template: %v", err)
	}
}

func (p *Portal) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "client_id": p.cfg.ClientID})
}

func (p *Portal) handleState(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	p.mu.RLock()
	defer p.mu.RUnlock()

	domains := map[string]DomainState{}
	for key, value := range p.domains {
		clone := *value
		clone.AccessToken = ""
		domains[key] = clone
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"client_id":    p.cfg.ClientID,
		"certificate":  "TPP demo certificate",
		"redirect_uri": p.cfg.RedirectURI,
		"domains":      domains,
	})
}

func (p *Portal) handleStart(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	domain := canonicalDomain(r.URL.Query().Get("domain"))
	if domain == "" {
		writeError(w, http.StatusBadRequest, "domain must be accounts, payments, or cof")
		return
	}

	consentID, status, expires, permissions, err := p.createConsent(r.Context(), domain)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}

	session, authURL, err := p.createPAR(r.Context(), domain, consentID)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}

	p.mu.Lock()
	p.pending[session.State] = session
	p.domains[domain] = &DomainState{
		Domain:        domain,
		ConsentID:     consentID,
		ConsentStatus: status,
		Expires:       expires,
		Permissions:   permissions,
		Security: SecurityProof{
			PAR:                 true,
			PKCE:                true,
			SignedRequestObject: true,
			MTLS:                true,
			ConsentID:           true,
			Detail:              "Awaiting real PSU authentication and consent approval",
		},
	}
	p.mu.Unlock()

	user, pass := persona(domain)
	writeJSON(w, http.StatusCreated, startResponse{
		Domain:        domain,
		ConsentID:     consentID,
		ConsentStatus: status,
		AuthURL:       authURL,
		Username:      user,
		Password:      pass,
		State:         session.State,
	})
}

func (p *Portal) handleCallback(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	io.WriteString(w, `<!doctype html>
<html>
<head><meta charset="utf-8"><title>FinLink authorization callback</title></head>
<body style="font-family:system-ui;background:#0b0f14;color:#e8edf2;padding:32px">
<h2>FinLink is validating the authorization response…</h2>
<pre id="status">Reading protected URL fragment.</pre>
<script>
(async () => {
  const status = document.getElementById("status");
  try {
    if (!window.location.hash) throw new Error("Authorization response fragment is missing");
    const res = await fetch("/callback/fragment", {
      method: "POST",
      headers: {"Content-Type":"application/json"},
      body: JSON.stringify({fragment: window.location.hash})
    });
    const body = await res.json();
    if (!res.ok) throw new Error(body.error || "callback validation failed");
    history.replaceState(null, "", "/callback");
    status.textContent = "Authorization verified. Returning to FinLink…";
    window.location.replace("/?authorized=" + encodeURIComponent(body.domain));
  } catch (e) {
    status.textContent = "ERROR: " + e.message;
  }
})();
</script></body></html>`)
}

func (p *Portal) handleCallbackFragment(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var input struct {
		Fragment string `json:"fragment"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&input); err != nil {
		writeError(w, http.StatusBadRequest, "invalid callback payload")
		return
	}

	domain, err := p.completeAuthorization(r.Context(), input.Fragment)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "domain": domain})
}

func (p *Portal) handleAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var input actionRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&input); err != nil {
		writeError(w, http.StatusBadRequest, "invalid action payload")
		return
	}
	input.Domain = canonicalDomain(input.Domain)
	if input.Domain == "" {
		writeError(w, http.StatusBadRequest, "invalid domain")
		return
	}

	resp, err := p.runAction(r.Context(), input)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

func (p *Portal) handleNegativeTests(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	result, err := p.runNegativeTests(r.Context())
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (p *Portal) handleReset(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	p.mu.Lock()
	p.domains = map[string]*DomainState{
		"accounts": {Domain: "accounts"},
		"payments": {Domain: "payments"},
		"cof":      {Domain: "cof"},
	}
	p.pending = map[string]*AuthSession{}
	p.mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "note": "portal memory reset only; no consent DB mutation performed"})
}

func canonicalDomain(input string) string {
	switch strings.ToLower(strings.TrimSpace(input)) {
	case "accounts":
		return "accounts"
	case "payments":
		return "payments"
	case "cof", "funds", "fundsconfirmations":
		return "cof"
	default:
		return ""
	}
}

func persona(domain string) (string, string) {
	switch domain {
	case "accounts":
		return "alice", "Alice@12345"
	case "payments":
		return "bob", "Bob@12345"
	case "cof":
		return "carol", "Carol@12345"
	}
	return "", ""
}

func scopeFor(domain string) string {
	if domain == "cof" {
		return "fundsconfirmations"
	}
	return domain
}

func baseFor(cfg Config, domain string) string {
	switch domain {
	case "accounts":
		return cfg.Gateway + "/open-banking/v3.1/aisp/3.1.0"
	case "payments":
		return cfg.Gateway + "/open-banking/v3.1/pisp/3.1.0"
	case "cof":
		return cfg.Gateway + "/open-banking/v3.1/cbpii/3.1.0"
	}
	return ""
}

func (p *Portal) createConsent(ctx context.Context, domain string) (string, string, string, []string, error) {
	token, err := p.applicationToken(ctx, scopeFor(domain))
	if err != nil {
		return "", "", "", nil, err
	}

	var path string
	var body any
	switch domain {
	case "accounts":
		path = "/account-access-consents"
		body = accountConsentPayload()
	case "payments":
		path = "/payment-consents"
		body = paymentConsentPayload()
	case "cof":
		path = "/funds-confirmation-consents"
		body = cofConsentPayload()
	default:
		return "", "", "", nil, errors.New("unsupported domain")
	}

	statusCode, raw, err := p.gatewayJSON(ctx, p.mtlsClient, http.MethodPost, baseFor(p.cfg, domain)+path, token, body, nil)
	if err != nil {
		return "", "", "", nil, err
	}
	if statusCode != http.StatusCreated {
		return "", "", "", nil, fmt.Errorf("create %s consent returned HTTP %d: %s", domain, statusCode, compact(raw))
	}

	var obj map[string]any
	if err := json.Unmarshal(raw, &obj); err != nil {
		return "", "", "", nil, err
	}
	id := recursiveString(obj, "ConsentId")
	status := recursiveString(obj, "Status")
	expires := recursiveString(obj, "ExpirationDateTime")
	permissions := recursiveStrings(obj, "Permissions")
	if id == "" {
		return "", "", "", nil, fmt.Errorf("%s consent response has no ConsentId: %s", domain, compact(raw))
	}
	if status == "" {
		status = "AwaitingAuthorisation"
	}
	return id, status, expires, permissions, nil
}

func accountConsentPayload() map[string]any {
	now := time.Now().UTC()
	return map[string]any{
		"Data": map[string]any{
			"Permissions": []string{
				"ReadAccountsBasic",
				"ReadAccountsDetail",
				"ReadBalances",
				"ReadTransactionsBasic",
				"ReadTransactionsDetail",
			},
			"ExpirationDateTime":      now.AddDate(1, 0, 0).Format(time.RFC3339),
			"TransactionFromDateTime": now.AddDate(0, -6, 0).Format(time.RFC3339),
			"TransactionToDateTime":   now.Format(time.RFC3339),
		},
		"Risk": map[string]any{},
	}
}

func paymentInitiation() map[string]any {
	return map[string]any{
		"InstructionIdentification": "INST-BOB-001",
		"EndToEndIdentification":    "E2E-BOB-001",
		"LocalInstrument":           "OB.FPS",
		"InstructedAmount": map[string]any{
			"Amount":   "149.90",
			"Currency": "USD",
		},
		"DebtorAccount": map[string]any{
			"SchemeName":     "OB.SortCodeAccountNumber",
			"Identification": "11280000000005",
			"Name":           "Bob Demo",
		},
		"CreditorAccount": map[string]any{
			"SchemeName":     "OB.SortCodeAccountNumber",
			"Identification": "08080021325698",
			"Name":           "Energia Sul",
		},
		"RemittanceInformation": map[string]any{
			"Reference":    "Electricity invoice SEP-2026",
			"Unstructured": "FinLink demo payment",
		},
	}
}

func paymentConsentPayload() map[string]any {
	return map[string]any{
		"Data": map[string]any{"Initiation": paymentInitiation()},
		"Risk": map[string]any{},
	}
}

func cofConsentPayload() map[string]any {
	return map[string]any{
		"Data": map[string]any{
			"ExpirationDateTime": time.Now().UTC().AddDate(1, 0, 0).Format(time.RFC3339),
			"DebtorAccount": map[string]any{
				"SchemeName":     "OB.SortCodeAccountNumber",
				"Identification": "11280000000007",
				"Name":           "Carol Demo",
			},
		},
		"Risk": map[string]any{},
	}
}

func (p *Portal) applicationToken(ctx context.Context, scope string) (string, error) {
	p.mu.RLock()
	cached, ok := p.appTokens[scope]
	p.mu.RUnlock()
	if ok && cached.Token != "" && time.Until(cached.Expiry) > 60*time.Second {
		return cached.Token, nil
	}

	form := url.Values{}
	form.Set("grant_type", "client_credentials")
	form.Set("client_id", p.cfg.ClientID)
	form.Set("scope", scope)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.cfg.IS+"/oauth2/token", strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")

	resp, err := p.mtlsClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("application token: %w", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("application token HTTP %d: %s", resp.StatusCode, compact(raw))
	}

	var out struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
		Scope       string `json:"scope"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return "", err
	}
	if out.AccessToken == "" {
		return "", errors.New("token endpoint returned no access_token")
	}
	exp := time.Now().Add(time.Duration(out.ExpiresIn) * time.Second)
	p.mu.Lock()
	p.appTokens[scope] = AppToken{Token: out.AccessToken, Expiry: exp}
	p.mu.Unlock()
	return out.AccessToken, nil
}

func (p *Portal) createPAR(ctx context.Context, domain, consentID string) (*AuthSession, string, error) {
	scope := scopeFor(domain)
	state := newUUID()
	nonce := newUUID()
	verifierBytes := make([]byte, 32)
	if _, err := rand.Read(verifierBytes); err != nil {
		return nil, "", err
	}
	verifier := hex.EncodeToString(verifierBytes)
	challengeHash := sha256.Sum256([]byte(verifier))
	challenge := base64.RawURLEncoding.EncodeToString(challengeHash[:])

	now := time.Now().Unix()
	intent := map[string]any{"value": consentID, "essential": true}
	claims := map[string]any{
		"aud":                   p.cfg.IS + "/oauth2/token",
		"iss":                   p.cfg.ClientID,
		"client_id":             p.cfg.ClientID,
		"response_type":         "code id_token",
		"scope":                 scope + " openid",
		"redirect_uri":          p.cfg.RedirectURI,
		"state":                 state,
		"nonce":                 nonce,
		"prompt":                "login",
		"max_age":               86400,
		"code_challenge":        challenge,
		"code_challenge_method": "S256",
		"nbf":                   now - 5,
		"iat":                   now,
		"exp":                   now + 600,
		"claims": map[string]any{
			"id_token": map[string]any{
				"acr": map[string]any{
					"values":    []string{"urn:openbanking:psd2:sca", "urn:openbanking:psd2:ca"},
					"essential": true,
				},
				"openbanking_intent_id": intent,
			},
			"userinfo": map[string]any{"openbanking_intent_id": intent},
		},
	}

	requestObject, err := p.signRequestObject(claims)
	if err != nil {
		return nil, "", err
	}

	form := url.Values{}
	form.Set("client_id", p.cfg.ClientID)
	form.Set("request", requestObject)
	form.Set("response_type", "code id_token")
	form.Set("scope", scope+" openid")
	form.Set("redirect_uri", p.cfg.RedirectURI)
	form.Set("state", state)
	form.Set("nonce", nonce)
	form.Set("prompt", "login")
	form.Set("code_challenge", challenge)
	form.Set("code_challenge_method", "S256")

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.cfg.IS+"/oauth2/par", strings.NewReader(form.Encode()))
	if err != nil {
		return nil, "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")

	resp, err := p.mtlsClient.Do(req)
	if err != nil {
		return nil, "", fmt.Errorf("PAR: %w", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	if resp.StatusCode != http.StatusCreated {
		return nil, "", fmt.Errorf("PAR HTTP %d: %s", resp.StatusCode, compact(raw))
	}

	var out struct {
		RequestURI string `json:"request_uri"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, "", err
	}
	if out.RequestURI == "" {
		return nil, "", errors.New("PAR response contains no request_uri")
	}

	q := url.Values{}
	q.Set("client_id", p.cfg.ClientID)
	q.Set("request_uri", out.RequestURI)
	authURL := p.cfg.IS + "/oauth2/authorize?" + q.Encode()

	session := &AuthSession{
		Domain:     domain,
		ConsentID:  consentID,
		State:      state,
		Nonce:      nonce,
		Verifier:   verifier,
		Scope:      scope,
		CreatedAt:  time.Now(),
		RequestURI: out.RequestURI,
	}
	return session, authURL, nil
}

func (p *Portal) signRequestObject(claims map[string]any) (string, error) {
	keyPEM, err := os.ReadFile(p.cfg.KeyPath)
	if err != nil {
		return "", err
	}
	block, _ := pem.Decode(keyPEM)
	if block == nil {
		return "", errors.New("TPP private key is not PEM")
	}

	var key *rsa.PrivateKey
	if parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes); err == nil {
		var ok bool
		key, ok = parsed.(*rsa.PrivateKey)
		if !ok {
			return "", errors.New("TPP private key is not RSA")
		}
	} else {
		key, err = x509.ParsePKCS1PrivateKey(block.Bytes)
		if err != nil {
			return "", fmt.Errorf("parse TPP private key: %w", err)
		}
	}

	header := map[string]any{"alg": "PS256", "typ": "JWT", "kid": p.cfg.KID}
	hb, _ := json.Marshal(header)
	pb, _ := json.Marshal(claims)
	signing := base64.RawURLEncoding.EncodeToString(hb) + "." + base64.RawURLEncoding.EncodeToString(pb)
	digest := sha256.Sum256([]byte(signing))
	sig, err := rsa.SignPSS(rand.Reader, key, crypto.SHA256, digest[:], &rsa.PSSOptions{
		SaltLength: rsa.PSSSaltLengthEqualsHash,
		Hash:       crypto.SHA256,
	})
	if err != nil {
		return "", err
	}
	return signing + "." + base64.RawURLEncoding.EncodeToString(sig), nil
}

func (p *Portal) completeAuthorization(ctx context.Context, fragment string) (string, error) {
	fragment = strings.TrimPrefix(strings.TrimSpace(fragment), "#")
	values, err := url.ParseQuery(fragment)
	if err != nil {
		return "", fmt.Errorf("parse authorization response: %w", err)
	}
	if oauthErr := values.Get("error"); oauthErr != "" {
		return "", fmt.Errorf("authorization error %s: %s", oauthErr, values.Get("error_description"))
	}

	code := values.Get("code")
	state := values.Get("state")
	idToken := values.Get("id_token")
	if code == "" || state == "" || idToken == "" {
		return "", errors.New("authorization response requires code, state, and id_token")
	}

	p.mu.RLock()
	session := p.pending[state]
	p.mu.RUnlock()
	if session == nil {
		return "", errors.New("state is unknown or authorization session already consumed")
	}
	if time.Since(session.CreatedAt) > 10*time.Minute {
		return "", errors.New("authorization session expired")
	}

	idClaims, err := p.verifyJWT(ctx, idToken)
	if err != nil {
		return "", fmt.Errorf("ID token signature: %w", err)
	}
	if err := validateIDClaims(idClaims, p.cfg, session, code); err != nil {
		return "", err
	}

	tokenResponse, err := p.exchangeCode(ctx, code, session)
	if err != nil {
		return "", err
	}
	accessToken, _ := tokenResponse["access_token"].(string)
	if accessToken == "" {
		return "", errors.New("authorization-code exchange returned no access_token")
	}

	accessClaims, err := p.verifyJWT(ctx, accessToken)
	if err != nil {
		return "", fmt.Errorf("access token signature: %w", err)
	}
	if err := p.validateAccessClaims(accessClaims, session); err != nil {
		return "", err
	}

	status, expires, permissions, err := p.getConsent(ctx, session.Domain, session.ConsentID)
	if err != nil {
		return "", err
	}
	if status != "Authorised" {
		return "", fmt.Errorf("consent %s status is %q, expected Authorised", session.ConsentID, status)
	}

	exp := jwtTime(accessClaims["exp"])
	p.mu.Lock()
	ds := p.domains[session.Domain]
	if ds == nil || ds.ConsentID != session.ConsentID {
		ds = &DomainState{Domain: session.Domain, ConsentID: session.ConsentID}
		p.domains[session.Domain] = ds
	}
	ds.ConsentStatus = status
	ds.Expires = expires
	ds.Permissions = permissions
	ds.Authorized = true
	ds.AccessToken = accessToken
	ds.TokenExpiry = exp
	ds.Security = SecurityProof{
		PAR:                  true,
		PKCE:                 true,
		SignedRequestObject:  true,
		MTLS:                 true,
		ConsentID:            true,
		IDTokenSignature:     true,
		AccessTokenSignature: true,
		CertificateBound:     true,
		Detail:               "Real PSU authorization verified; code exchanged exactly once with PKCE + mTLS",
	}
	delete(p.pending, state)
	p.mu.Unlock()

	return session.Domain, nil
}

func validateIDClaims(claims map[string]any, cfg Config, session *AuthSession, code string) error {
	if stringClaim(claims, "iss") != cfg.IS+"/oauth2/token" {
		return fmt.Errorf("ID token issuer mismatch")
	}
	if !audienceContains(claims["aud"], cfg.ClientID) {
		return fmt.Errorf("ID token audience mismatch")
	}
	if azp := stringClaim(claims, "azp"); azp != "" && azp != cfg.ClientID {
		return fmt.Errorf("ID token azp mismatch")
	}
	if stringClaim(claims, "nonce") != session.Nonce {
		return fmt.Errorf("ID token nonce mismatch")
	}
	if stringClaim(claims, "consent_id") != session.ConsentID {
		return fmt.Errorf("ID token consent_id mismatch")
	}
	if err := validateJWTTime(claims); err != nil {
		return err
	}
	if ch := stringClaim(claims, "c_hash"); ch != "" && ch != oidcHalfHash(code) {
		return fmt.Errorf("ID token c_hash mismatch")
	}
	if sh := stringClaim(claims, "s_hash"); sh != "" && sh != oidcHalfHash(session.State) {
		return fmt.Errorf("ID token s_hash mismatch")
	}
	return nil
}

func (p *Portal) exchangeCode(ctx context.Context, code string, session *AuthSession) (map[string]any, error) {
	form := url.Values{}
	form.Set("grant_type", "authorization_code")
	form.Set("code", code)
	form.Set("redirect_uri", p.cfg.RedirectURI)
	form.Set("client_id", p.cfg.ClientID)
	form.Set("code_verifier", session.Verifier)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.cfg.IS+"/oauth2/token", strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")

	resp, err := p.mtlsClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("authorization-code exchange HTTP %d: %s", resp.StatusCode, compact(raw))
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, err
	}
	return out, nil
}

func (p *Portal) validateAccessClaims(claims map[string]any, session *AuthSession) error {
	if stringClaim(claims, "iss") != p.cfg.IS+"/oauth2/token" {
		return errors.New("access token issuer mismatch")
	}
	if !audienceContains(claims["aud"], p.cfg.ClientID) {
		return errors.New("access token audience mismatch")
	}
	client := stringClaim(claims, "client_id")
	if client == "" {
		client = stringClaim(claims, "azp")
	}
	if client != p.cfg.ClientID {
		return errors.New("access token client mismatch")
	}
	if !strings.Contains(" "+stringClaim(claims, "scope")+" ", " "+session.Scope+" ") {
		return fmt.Errorf("access token missing %s scope", session.Scope)
	}
	if stringClaim(claims, "consent_id") != session.ConsentID {
		return errors.New("access token consent_id mismatch")
	}
	if err := validateJWTTime(claims); err != nil {
		return err
	}
	cnf, _ := claims["cnf"].(map[string]any)
	if cnf == nil {
		return errors.New("access token has no cnf")
	}
	expected, err := certificateThumbprint(p.cfg.CertPath)
	if err != nil {
		return err
	}
	if value, _ := cnf["x5t#S256"].(string); value != expected {
		return errors.New("access token x5t#S256 does not match TPP certificate")
	}
	return nil
}

func certificateThumbprint(certPath string) (string, error) {
	pemData, err := os.ReadFile(certPath)
	if err != nil {
		return "", err
	}
	block, _ := pem.Decode(pemData)
	if block == nil {
		return "", errors.New("certificate is not PEM")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(cert.Raw)
	return base64.RawURLEncoding.EncodeToString(sum[:]), nil
}

func accessTokenFingerprint(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:8])
}

func (p *Portal) handleAccountsConsentLifecycle(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	p.mu.RLock()
	ds := p.domains["accounts"]
	if ds == nil || ds.ConsentID == "" {
		p.mu.RUnlock()
		writeError(w, http.StatusConflict, "accounts consent is not available; authorize Accounts first")
		return
	}
	consentID := ds.ConsentID
	token := ds.AccessToken
	p.mu.RUnlock()

	status, expires, permissions, err := p.getConsent(r.Context(), "accounts", consentID)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}

	fingerprint := ""
	if token != "" {
		fingerprint = accessTokenFingerprint(token)
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"consent_id":           consentID,
		"consent_status":       status,
		"expires":              expires,
		"permissions":          permissions,
		"portal_url":           p.cfg.IS + "/consentmgr",
		"resource_url":         baseFor(p.cfg, "accounts") + "/accounts",
		"access_token_present": token != "",
		"token_fingerprint":    fingerprint,
	})
}

func (p *Portal) handleAccountsConsentRetest(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	p.mu.RLock()
	ds := p.domains["accounts"]
	if ds == nil || ds.ConsentID == "" || ds.AccessToken == "" {
		p.mu.RUnlock()
		writeError(w, http.StatusConflict, "Accounts must be authorized before the lifecycle retest")
		return
	}
	consentID := ds.ConsentID
	token := ds.AccessToken
	p.mu.RUnlock()

	endpoint := baseFor(p.cfg, "accounts") + "/accounts"
	fingerprint := accessTokenFingerprint(token)

	code, raw, err := p.gatewayJSON(
		r.Context(),
		p.mtlsClient,
		http.MethodGet,
		endpoint,
		token,
		nil,
		nil,
	)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"request": map[string]any{
			"method":            http.MethodGet,
			"url":               endpoint,
			"consent_id":        consentID,
			"token_fingerprint": fingerprint,
			"mtls":              true,
		},
		"http":     code,
		"rejected": code < 200 || code >= 300,
		"response": decodeAny(raw),
	})
}

func (p *Portal) getConsent(ctx context.Context, domain, consentID string) (string, string, []string, error) {
	appToken, err := p.applicationToken(ctx, scopeFor(domain))
	if err != nil {
		return "", "", nil, err
	}
	var path string
	switch domain {
	case "accounts":
		path = "/account-access-consents/"
	case "payments":
		path = "/payment-consents/"
	case "cof":
		path = "/funds-confirmation-consents/"
	}
	code, raw, err := p.gatewayJSON(ctx, p.mtlsClient, http.MethodGet, baseFor(p.cfg, domain)+path+url.PathEscape(consentID), appToken, nil, nil)
	if err != nil {
		return "", "", nil, err
	}
	if code != http.StatusOK {
		return "", "", nil, fmt.Errorf("read consent HTTP %d: %s", code, compact(raw))
	}
	var obj map[string]any
	if err := json.Unmarshal(raw, &obj); err != nil {
		return "", "", nil, err
	}
	return recursiveString(obj, "Status"), recursiveString(obj, "ExpirationDateTime"), recursiveStrings(obj, "Permissions"), nil
}

func (p *Portal) runAction(ctx context.Context, in actionRequest) (actionResponse, error) {
	p.mu.RLock()
	ds := p.domains[in.Domain]
	if ds == nil || !ds.Authorized || ds.AccessToken == "" {
		p.mu.RUnlock()
		return actionResponse{}, fmt.Errorf("%s is not authorised; request and approve consent first", in.Domain)
	}
	token := ds.AccessToken
	consentID := ds.ConsentID
	paymentID := ds.PaymentID
	paymentIdemKey := ds.PaymentIdemKey
	p.mu.RUnlock()

	switch in.Domain {
	case "accounts":
		return p.accountAction(ctx, token, in)
	case "payments":
		return p.paymentAction(ctx, token, consentID, paymentID, paymentIdemKey, in)
	case "cof":
		return p.cofAction(ctx, token, consentID, in)
	}
	return actionResponse{}, errors.New("unsupported action")
}

func (p *Portal) accountAction(ctx context.Context, token string, in actionRequest) (actionResponse, error) {
	var endpoint string
	switch in.Action {
	case "accounts":
		endpoint = "/accounts"
	case "balances":
		if in.AccountID == "" {
			return actionResponse{}, errors.New("account_id required for balances")
		}
		endpoint = "/accounts/" + url.PathEscape(in.AccountID) + "/balances"
	case "transactions":
		if in.AccountID == "" {
			return actionResponse{}, errors.New("account_id required for transactions")
		}
		endpoint = "/accounts/" + url.PathEscape(in.AccountID) + "/transactions"
	default:
		return actionResponse{}, errors.New("accounts action must be accounts, balances, or transactions")
	}

	code, raw, err := p.gatewayJSON(ctx, p.mtlsClient, http.MethodGet, baseFor(p.cfg, "accounts")+endpoint, token, nil, nil)
	if err != nil {
		return actionResponse{}, err
	}
	data := decodeAny(raw)
	if code != http.StatusOK {
		return actionResponse{}, fmt.Errorf("Accounts API HTTP %d: %s", code, compact(raw))
	}

	if in.Action == "accounts" {
		ids := collectStringsByKey(data, "AccountId")
		sort.Strings(ids)
		ids = unique(ids)
		p.mu.Lock()
		p.domains["accounts"].AccountIDs = ids
		p.domains["accounts"].LastResult = data
		p.domains["accounts"].LastHTTP = code
		p.mu.Unlock()
	} else {
		p.mu.Lock()
		p.domains["accounts"].LastResult = data
		p.domains["accounts"].LastHTTP = code
		p.mu.Unlock()
	}
	return actionResponse{HTTP: code, Data: data}, nil
}

func (p *Portal) paymentAction(ctx context.Context, token, consentID, paymentID, idempotencyKey string, in actionRequest) (actionResponse, error) {
	switch in.Action {
	case "execute":
		if idempotencyKey == "" {
			idempotencyKey = newUUID()
		}
		body := map[string]any{
			"Data": map[string]any{
				"ConsentId":  consentID,
				"Initiation": paymentInitiation(),
			},
			"Risk": map[string]any{},
		}
		headers := map[string]string{"x-idempotency-key": idempotencyKey}
		code, raw, err := p.gatewayJSON(ctx, p.mtlsClient, http.MethodPost, baseFor(p.cfg, "payments")+"/domestic-payments", token, body, headers)
		if err != nil {
			return actionResponse{}, err
		}
		data := decodeAny(raw)
		if code != http.StatusCreated && code != http.StatusOK {
			return actionResponse{}, fmt.Errorf("payment execution HTTP %d: %s", code, compact(raw))
		}
		id := recursiveStringAny(data, "DomesticPaymentId")
		if id == "" {
			id = recursiveStringAny(data, "PaymentId")
		}
		if id == "" {
			return actionResponse{}, fmt.Errorf("payment response contains no payment ID: %s", compact(raw))
		}
		p.mu.Lock()
		p.domains["payments"].PaymentID = id
		p.domains["payments"].PaymentIdemKey = idempotencyKey
		p.domains["payments"].LastResult = data
		p.domains["payments"].LastHTTP = code
		p.mu.Unlock()
		return actionResponse{HTTP: code, Data: data}, nil

	case "status":
		if paymentID == "" {
			return actionResponse{}, errors.New("execute a payment first")
		}
		code, raw, err := p.gatewayJSON(ctx, p.mtlsClient, http.MethodGet, baseFor(p.cfg, "payments")+"/domestic-payments/"+url.PathEscape(paymentID), token, nil, nil)
		if err != nil {
			return actionResponse{}, err
		}
		data := decodeAny(raw)
		if code != http.StatusOK {
			return actionResponse{}, fmt.Errorf("payment status HTTP %d: %s", code, compact(raw))
		}
		p.mu.Lock()
		p.domains["payments"].LastResult = data
		p.domains["payments"].LastHTTP = code
		p.mu.Unlock()
		return actionResponse{HTTP: code, Data: data}, nil
	default:
		return actionResponse{}, errors.New("payments action must be execute or status")
	}
}

func (p *Portal) cofAction(ctx context.Context, token, consentID string, in actionRequest) (actionResponse, error) {
	if in.Action != "check" {
		return actionResponse{}, errors.New("CoF action must be check")
	}
	amount := strings.TrimSpace(in.Amount)
	if amount == "" {
		amount = "10.00"
	}
	currency := strings.ToUpper(strings.TrimSpace(in.Currency))
	if currency == "" {
		currency = "USD"
	}
	body := map[string]any{
		"Data": map[string]any{
			"ConsentId":        consentID,
			"Reference":        "FINLINK-COF-" + strings.ToUpper(strings.ReplaceAll(newUUID()[:8], "-", "")),
			"InstructedAmount": map[string]any{"Amount": amount, "Currency": currency},
		},
	}
	code, raw, err := p.gatewayJSON(ctx, p.mtlsClient, http.MethodPost, baseFor(p.cfg, "cof")+"/funds-confirmations", token, body, nil)
	if err != nil {
		return actionResponse{}, err
	}
	data := decodeAny(raw)
	if code != http.StatusCreated {
		return actionResponse{}, fmt.Errorf("CoF HTTP %d: %s", code, compact(raw))
	}
	p.mu.Lock()
	p.domains["cof"].LastResult = data
	p.domains["cof"].LastHTTP = code
	p.mu.Unlock()
	return actionResponse{HTTP: code, Data: data}, nil
}

func (p *Portal) runNegativeTests(ctx context.Context) (map[string]any, error) {
	result := map[string]any{}

	p.mu.RLock()
	accounts := cloneDomain(p.domains["accounts"])
	payments := cloneDomain(p.domains["payments"])
	cof := cloneDomain(p.domains["cof"])
	p.mu.RUnlock()

	if accounts == nil || !accounts.Authorized {
		return nil, errors.New("authorize Accounts before running negative tests")
	}
	if payments == nil || !payments.Authorized {
		return nil, errors.New("authorize Payments before running negative tests")
	}
	if cof == nil || !cof.Authorized {
		return nil, errors.New("authorize Confirmation of Funds before running negative tests")
	}

	// 1. A certificate-bound Accounts token must fail if FinLink omits its client certificate.
	code, raw, err := p.gatewayJSON(ctx, p.httpClient, http.MethodGet, baseFor(p.cfg, "accounts")+"/accounts", accounts.AccessToken, nil, nil)
	if err != nil {
		result["accounts_without_mtls"] = map[string]any{
			"http":            0,
			"passed":          true,
			"transport_error": err.Error(),
		}
	} else {
		result["accounts_without_mtls"] = map[string]any{
			"http":     code,
			"passed":   code < 200 || code >= 300,
			"response": decodeAny(raw),
		}
	}

	// 2. A payments-scoped token must not authorize the Accounts resource.
	code, raw, err = p.gatewayJSON(ctx, p.mtlsClient, http.MethodGet, baseFor(p.cfg, "accounts")+"/accounts", payments.AccessToken, nil, nil)
	if err != nil {
		return nil, err
	}
	result["wrong_scope_payments_to_accounts"] = map[string]any{
		"http":     code,
		"passed":   code < 200 || code >= 300,
		"response": decodeAny(raw),
	}

	// 3. Tamper with the authorised Payment Risk object. Bank consent validation must reject it.
	tamperedPayment := map[string]any{
		"Data": map[string]any{
			"ConsentId":  payments.ConsentID,
			"Initiation": paymentInitiation(),
		},
		"Risk": map[string]any{"PaymentContextCode": "EcommerceGoods"},
	}
	code, raw, err = p.gatewayJSON(ctx, p.mtlsClient, http.MethodPost, baseFor(p.cfg, "payments")+"/domestic-payments", payments.AccessToken, tamperedPayment, map[string]string{"x-idempotency-key": newUUID()})
	if err != nil {
		return nil, err
	}
	result["payment_risk_tamper"] = map[string]any{
		"http":     code,
		"passed":   code == http.StatusBadRequest,
		"response": decodeAny(raw),
	}

	// 4. Carol's consent-bound account is USD; EUR must be rejected.
	wrongCurrency := map[string]any{
		"Data": map[string]any{
			"ConsentId":        cof.ConsentID,
			"Reference":        "FINLINK-NEGATIVE-CURRENCY",
			"InstructedAmount": map[string]any{"Amount": "10.00", "Currency": "EUR"},
		},
	}
	code, raw, err = p.gatewayJSON(ctx, p.mtlsClient, http.MethodPost, baseFor(p.cfg, "cof")+"/funds-confirmations", cof.AccessToken, wrongCurrency, nil)
	if err != nil {
		return nil, err
	}
	result["cof_wrong_currency"] = map[string]any{
		"http":     code,
		"passed":   code == http.StatusBadRequest,
		"response": decodeAny(raw),
	}

	passed := true
	for _, value := range result {
		m, _ := value.(map[string]any)
		ok, _ := m["passed"].(bool)
		passed = passed && ok
	}
	result["all_passed"] = passed
	return result, nil
}

func cloneDomain(ds *DomainState) *DomainState {
	if ds == nil {
		return nil
	}
	c := *ds
	return &c
}

func (p *Portal) gatewayJSON(ctx context.Context, client *http.Client, method, endpoint, token string, body any, extra map[string]string) (int, []byte, error) {
	var reader io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return 0, nil, err
		}
		reader = bytes.NewReader(b)
	}

	req, err := http.NewRequestWithContext(ctx, method, endpoint, reader)
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	req.Header.Set("x-fapi-financial-id", "open-bank")
	req.Header.Set("x-fapi-interaction-id", newUUID())
	for key, value := range extra {
		req.Header.Set(key, value)
	}

	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	return resp.StatusCode, raw, err
}

func (p *Portal) verifyJWT(ctx context.Context, token string) (map[string]any, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, errors.New("JWT must contain 3 segments")
	}
	hb, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, err
	}
	pb, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, err
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return nil, err
	}

	var header map[string]any
	if err := json.Unmarshal(hb, &header); err != nil {
		return nil, err
	}
	alg := stringClaim(header, "alg")
	kid := stringClaim(header, "kid")
	if alg != "PS256" && alg != "RS256" {
		return nil, fmt.Errorf("unsupported JWT alg %q", alg)
	}
	if kid == "" {
		return nil, errors.New("JWT kid missing")
	}

	key, err := p.jwkKey(ctx, kid)
	if err != nil {
		return nil, err
	}
	signing := parts[0] + "." + parts[1]
	digest := sha256.Sum256([]byte(signing))
	switch alg {
	case "PS256":
		err = rsa.VerifyPSS(key, crypto.SHA256, digest[:], sig, &rsa.PSSOptions{
			SaltLength: rsa.PSSSaltLengthAuto,
			Hash:       crypto.SHA256,
		})
	case "RS256":
		err = rsa.VerifyPKCS1v15(key, crypto.SHA256, digest[:], sig)
	}
	if err != nil {
		return nil, fmt.Errorf("JWT signature invalid: %w", err)
	}

	var claims map[string]any
	if err := json.Unmarshal(pb, &claims); err != nil {
		return nil, err
	}
	return claims, nil
}

func (p *Portal) jwkKey(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	p.mu.RLock()
	if key := p.jwks[kid]; key != nil && time.Since(p.jwksAt) < 5*time.Minute {
		p.mu.RUnlock()
		return key, nil
	}
	p.mu.RUnlock()

	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, p.cfg.IS+"/oauth2/jwks", nil)
	resp, err := p.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("JWKS HTTP %d", resp.StatusCode)
	}

	var doc struct {
		Keys []struct {
			KID string `json:"kid"`
			KTY string `json:"kty"`
			N   string `json:"n"`
			E   string `json:"e"`
		} `json:"keys"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, err
	}

	keys := map[string]*rsa.PublicKey{}
	for _, jwk := range doc.Keys {
		if jwk.KTY != "RSA" || jwk.KID == "" {
			continue
		}
		nBytes, err := base64.RawURLEncoding.DecodeString(jwk.N)
		if err != nil {
			continue
		}
		eBytes, err := base64.RawURLEncoding.DecodeString(jwk.E)
		if err != nil || len(eBytes) == 0 || len(eBytes) > 4 {
			continue
		}
		e := 0
		for _, b := range eBytes {
			e = e<<8 | int(b)
		}
		if e < 3 {
			continue
		}
		keys[jwk.KID] = &rsa.PublicKey{N: new(big.Int).SetBytes(nBytes), E: e}
	}

	// The small wrapper above keeps the implementation standard-library-only
	// while avoiding math/big references outside this helper.
	if len(keys) == 0 {
		return nil, errors.New("JWKS contained no usable RSA keys")
	}
	p.mu.Lock()
	p.jwks = keys
	p.jwksAt = time.Now()
	key := p.jwks[kid]
	p.mu.Unlock()
	if key == nil {
		return nil, fmt.Errorf("JWKS has no key for kid %s", kid)
	}
	return key, nil
}

func validateJWTTime(claims map[string]any) error {
	now := time.Now()
	if exp := jwtTime(claims["exp"]); exp.IsZero() || !exp.After(now) {
		return errors.New("JWT expired or exp missing")
	}
	if nbf := jwtTime(claims["nbf"]); !nbf.IsZero() && now.Add(10*time.Second).Before(nbf) {
		return errors.New("JWT not active yet")
	}
	return nil
}

func jwtTime(value any) time.Time {
	switch v := value.(type) {
	case float64:
		return time.Unix(int64(v), 0)
	case json.Number:
		n, _ := v.Int64()
		return time.Unix(n, 0)
	}
	return time.Time{}
}

func audienceContains(value any, expected string) bool {
	switch v := value.(type) {
	case string:
		return v == expected
	case []any:
		for _, item := range v {
			if s, ok := item.(string); ok && s == expected {
				return true
			}
		}
	}
	return false
}

func oidcHalfHash(value string) string {
	sum := sha256.Sum256([]byte(value))
	return base64.RawURLEncoding.EncodeToString(sum[:len(sum)/2])
}

func stringClaim(obj map[string]any, key string) string {
	value, _ := obj[key].(string)
	return value
}

func recursiveString(obj map[string]any, key string) string {
	return recursiveStringAny(obj, key)
}

func recursiveStringAny(value any, key string) string {
	switch v := value.(type) {
	case map[string]any:
		if s, ok := v[key].(string); ok {
			return s
		}
		for _, child := range v {
			if s := recursiveStringAny(child, key); s != "" {
				return s
			}
		}
	case []any:
		for _, child := range v {
			if s := recursiveStringAny(child, key); s != "" {
				return s
			}
		}
	}
	return ""
}

func recursiveStrings(obj map[string]any, key string) []string {
	var out []string
	var walk func(any)
	walk = func(value any) {
		switch v := value.(type) {
		case map[string]any:
			if raw, ok := v[key].([]any); ok {
				for _, item := range raw {
					if s, ok := item.(string); ok {
						out = append(out, s)
					}
				}
			}
			for _, child := range v {
				walk(child)
			}
		case []any:
			for _, child := range v {
				walk(child)
			}
		}
	}
	walk(obj)
	return unique(out)
}

func collectStringsByKey(value any, key string) []string {
	var out []string
	var walk func(any)
	walk = func(v any) {
		switch x := v.(type) {
		case map[string]any:
			if s, ok := x[key].(string); ok && s != "" {
				out = append(out, s)
			}
			for _, child := range x {
				walk(child)
			}
		case []any:
			for _, child := range x {
				walk(child)
			}
		}
	}
	walk(value)
	return out
}

func unique(in []string) []string {
	seen := map[string]bool{}
	out := make([]string, 0, len(in))
	for _, s := range in {
		if s != "" && !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

func decodeAny(raw []byte) any {
	if len(bytes.TrimSpace(raw)) == 0 {
		return map[string]any{}
	}
	var value any
	if err := json.Unmarshal(raw, &value); err != nil {
		return string(raw)
	}
	return value
}

func compact(raw []byte) string {
	s := strings.TrimSpace(string(raw))
	if len(s) > 1000 {
		s = s[:1000] + "…"
	}
	return s
}

func newUUID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	h := hex.EncodeToString(b)
	return fmt.Sprintf("%s-%s-%s-%s-%s", h[0:8], h[8:12], h[12:16], h[16:20], h[20:32])
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(value)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]any{"error": message})
}
