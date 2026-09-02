# Demo story — Acme Bank opens APIs to FinLink

## Act 1 — Governance before connectivity

Acme Bank wants to expose customer data and payment capabilities to an external fintech without turning the core banking estate into a public endpoint. Show the APIs in APIM Publisher, their lifecycle state, version, resources, scopes and deployed revision. Explain that the bank can govern the product independently of the backend implementation.

## Act 2 — Establish trust

FinLink is represented by the generated TPP transport certificate. Explain the two distinct trust decisions: client/application identity at the authorization server, and transport identity at the API gateway. Show the certificate issuer/fingerprint and the shared trust chain. In a real bank, substitute the demo CA with the trusted regulatory/eIDAS/local PKI chain.

## Act 3 — Consent, not just OAuth

Create an account-access consent with granular permissions. The Accelerator owns the consent lifecycle. Redirect the customer to IS for authentication/authorization; the customer approves exactly what FinLink may read. The resulting user token carries the configured `consent_id` claim. Gateway consent enforcement calls the consent service before allowing the API request.

## Act 4 — Account aggregation

Call Accounts, Balances and Transactions through APIM. Use the mock data to show multiple account types/currencies and a credible transaction history. Make clear that APIM is enforcing the contract/security while the Go service remains the domain backend.

## Act 5 — Consent is live policy state

After Alice authorizes Accounts, call `/accounts` through APIM and show the successful response. Open the WSO2 Consent Manager, locate the exact Accounts consent, and revoke it. Then repeat the same `/accounts` request from FinLink with the same access token and the same mTLS client certificate. The request must now be rejected. Explain that the OAuth token still exists, but authorization depends on the current consent lifecycle state enforced at request time.

## Act 6 — Payment initiation

Create/authorize payment consent, then POST a domestic payment with `x-idempotency-key`. The backend debits the account in-memory and emits a matching booked transaction. Repeating the same idempotency key returns the same payment instead of creating a duplicate.

## Act 7 — Confirmation of Funds

A permitted party asks whether an account can cover a given amount. The API returns a boolean without exposing the actual balance, demonstrating data minimization.

## Act 7 — Failure paths

Show these controls deliberately:

- no client certificate → MTLS policy rejects
- bearer token from a different transport identity → certificate-bound/FAPI control should reject when enabled in the client profile
- missing/invalid/revoked/expired consent → Consent Enforcement rejects
- wrong OAuth scope → gateway/authorization validation rejects
- malformed request → schema validation rejects when enabled in Publisher
- repeated payment idempotency key → no duplicate payment
- excessive traffic → APIM throttling policy

## Business message

The demo is not “three WSO2 products in Docker.” It is an end-to-end trust chain: **TPP identity → customer authentication → explicit consent → financial-grade token → mTLS API call → governed API → bank system of record → auditable control points**.
