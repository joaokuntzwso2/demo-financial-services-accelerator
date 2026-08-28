# Architecture

```text
External TPP / FinLink
     |  mTLS + OAuth2/FAPI token + consent_id
     v
+--------------------------+
| WSO2 API Manager 4.7     |
| Publisher / DevPortal    |
| Classic Gateway          |
| FS mediation policies    |
+-------------+------------+
              | token validation / DCR / API resources / roles
              | consent validation + consent CRUD routing
              v
+--------------------------+
| WSO2 Identity Server 7.3 |
| OAuth2/OIDC/FAPI AS      |
| SCA / customer login     |
| FS consent + eventing    |
+--------------------------+
              ^
              |
              +---------------------------+
                                          |
APIM Dynamic Endpoint --------------------+ (consent paths)
      |
      +--------------------------------------> Go bank backend
                                               accounts/payments/CoF

MySQL 8.0 supplies separate APIM, IS and Financial Services schemas.
```

## Runtime boundaries

The Go service deliberately models the bank's system-of-record boundary. Consent state belongs in the Accelerator/IS domain; API product state belongs in APIM; customer account/payment data belongs in the mocked bank domain. This keeps the demo architecturally honest.

## Policy order

For protected API operations the bootstrap attaches:

1. MTLS Enforcement
2. Consent Enforcement
3. Dynamic Endpoint

Dynamic Endpoint is last because it changes the Synapse destination (`To`) header.
