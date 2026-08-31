#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
[[ -f .env ]] && set -a && source .env && set +a
cat <<'EOF'

=== Acme Bank / FinLink TPP demo walkthrough ===

The platform bootstrap has already installed the Accelerator, integrated IS as Key Manager,
and published Accounts, Payments and Confirmation of Funds APIs.

Recommended live presentation sequence:

1. Show backend data volume
EOF
curl -fsS "http://localhost:${BANK_BACKEND_PORT:-8080}/demo/summary" | jq
cat <<EOF

2. Show the API products in Publisher
   https://localhost:${APIM_HTTPS_PORT:-9443}/publisher

3. Show IS as the financial-grade authorization server
   https://localhost:${IS_HTTPS_PORT:-9446}/console

4. Inspect the generated TPP transport certificate
EOF
openssl x509 -in .state/certs/tpp.crt -noout -subject -issuer -fingerprint -sha256
cat <<EOF

5. Demonstrate that the bank backend is NOT the public API surface:
   internal domain service: http://localhost:${BANK_BACKEND_PORT:-8080}/api/fs/backend/services/accounts/accountservice/accounts
   public contract:         https://localhost:${APIM_GATEWAY_HTTPS_PORT:-8243}/open-banking/v3.1/aisp/accounts

6. Use the Publisher UI to inspect operation policies:
   Consent-management operations:
     MTLS Enforcement -> Dynamic Endpoint
   Protected banking-data operations:
     MTLS Enforcement -> Consent Enforcement -> Dynamic Endpoint (last).

7. For a customer authorization demonstration, use the Financial Services Accelerator's consent
   flow from the Accounts API: create an account-access consent, send the signed request object to
   IS /oauth2/authorize, authenticate the customer, approve the consent, exchange the code, then
   call /accounts with the TPP mTLS certificate.

The repository intentionally does not fake a browser approval by writing directly to consent tables.
That would bypass the control you are trying to demonstrate. demo/requests/ contains payloads to
use while presenting the flow.
EOF
