# WSO2 Open Banking E2E Demo — APIM 4.7 + IS 7.3 + Financial Services Accelerator 4.0

A reproducible local banking demo that combines:

- WSO2 API Manager **4.7.0** in Docker
- WSO2 Identity Server **7.3.0** in Docker
- WSO2 Financial Services / Open Banking IAM Accelerator **4.0.0** installed into Identity Server
- WSO2 Financial Services APIM Mediation Policies **1.0.0** installed into API Manager
- MySQL 8.0 for the APIM/IS/Financial Services databases
- A realistic Go mock bank backend with Accounts, Balances, Transactions, Payments and Confirmation of Funds data
- A Go TPP helper for financial-grade client credentials and browser authorization scaffolding
- Automated certificate generation, trust exchange, DB initialization, IS/APIM integration, API import, policy import/attachment, revision deployment and publication
- Runtime compatibility gates and smoke tests

> **Compatibility warning — intentional demo constraint**
>
> As of 2026-08-27, WSO2's published Financial Services Accelerator 4.0 compatibility matrix documents base products only through **APIM 4.6.0** and **IS 7.2.0**. This repository intentionally targets **APIM 4.7.0 + IS 7.3.0** because that is the requested demo combination. `./start.sh` therefore treats the combination as an explicit compatibility experiment and performs runtime gates. Do not present it as a WSO2-certified production matrix unless WSO2 confirms support for the exact update levels you deploy.

> **Build fix (2026-08-27):** the IS Docker image runs the Financial Services IAM Accelerator `merge.sh` from the accelerator `bin/` directory, as required by WSO2. This avoids the `Product home is: /` / `not a valid carbon product path` failure.

## What the demo tells

**Persona:** Maria is a retail-banking customer. **FinLink** is an external TPP/fintech. **Acme Bank** exposes Open Banking APIs.

The platform shows the separation of responsibilities:

- **API Manager**: API product lifecycle, gateway, subscriptions/governance, throttling, mTLS enforcement and Open Banking gateway policies.
- **Identity Server**: OAuth2/OIDC/FAPI authorization server, customer authentication, client registration/key management and token issuance.
- **Financial Services IAM Accelerator**: Open Banking consent, DCR/SSA extensions, eventing and banking-specific identity/runtime extensions on IS.
- **Financial Services APIM mediation policies**: mTLS enforcement, consent enforcement, dynamic endpoint routing, custom Synapse sequences and mediator/handler JARs on APIM.
- **Go bank backend**: the bank's core/domain services. WSO2 does not pretend to be the core banking system.

## Quick start

Prerequisites:

- Docker Desktop / Docker Engine + Compose v2
- OpenSSL
- `bash`, `curl`, `jq`
- At least 12 GB RAM available to Docker (16 GB recommended for a smoother local demo)
- Internet access on first run to pull images/dependencies, unless `dist/` is pre-populated

```bash
cp .env.example .env
./start.sh
```

The script performs:

1. Generates a local demo CA, APIM/IS TLS identities and a TPP mTLS certificate.
2. Obtains the official IAM Accelerator 4.0.0 ZIP for IS (release download by default, source/local modes available) and prepares the APIM Financial Services Mediation Policies 1.0.0 from the pinned WSO2 source tag.
3. Downloads the supported MySQL Connector/J and the WSO2 IS→APIM token-revocation event handler.
4. Builds IS 7.3 with the IAM Accelerator `merge.sh`; builds APIM 4.7 with the Financial Services mediation-policy JARs, custom sequences and policy templates in the documented APIM locations.
5. Starts MySQL and the Go bank backend.
6. Initializes all APIM, IS and Financial Services schemas from the actual built product images.
7. Starts IS, then APIM.
8. Validates that the products and Financial Services endpoints/classes are alive.
9. Creates APIM management credentials, verifies/configures the IS 7.x Key Manager integration, imports the banking APIs, uploads and attaches the Financial Services API-level policies, creates revisions, deploys them to the Default Gateway and publishes them.
10. Runs platform and backend smoke tests.

After startup:

| Component | URL / port |
|---|---|
| APIM Publisher | https://localhost:9443/publisher |
| APIM Developer Portal | https://localhost:9443/devportal |
| APIM Admin | https://localhost:9443/admin |
| APIM Gateway | https://localhost:8243 |
| Identity Server Console | https://localhost:9446/console |
| Identity Server My Account | https://localhost:9446/myaccount |
| Mock bank backend | http://localhost:8080 |
| Backend demo data summary | http://localhost:8080/demo/summary |

Default local admin credentials are `admin/admin`. These credentials are **demo-only**.

## Demo commands

```bash
# platform status and compatibility gates
./scripts/verify.sh

# inspect mocked banking data directly
curl -s http://localhost:8080/api/fs/backend/services/accounts/accountservice/accounts | jq

# run TPP walkthrough preparation / inspect generated financial-grade artifacts
./demo/run.sh

# logs
./logs.sh

# stop but preserve DB state
./stop.sh

# destroy all local state and certificates
./reset.sh
```

## Banking APIs created automatically in APIM

The bootstrap imports and publishes three APIs with Open Banking-style contexts:

- **Accounts API** — `/open-banking/v3.1/aisp`
- **Payments API** — `/open-banking/v3.1/pisp`
- **Confirmation of Funds API** — `/open-banking/v3.1/cbpii`

The API definitions are under `apis/`. They include schema validation-friendly request/response contracts and OAuth2 operation metadata. The bootstrap attaches, in request order:

1. **MTLS Enforcement Policy**
2. **Consent Enforcement Policy**
3. **Dynamic Endpoint Policy** — last, because it modifies the Synapse `To` header

The Dynamic Endpoint policy routes consent-management resources to IS Financial Services consent services and bank-domain resources to the Go backend.

A DCR API definition and bootstrap helper are also included under `apis/dcr.yaml` and `demo/`. DCR is kept separate from the three resource APIs because its transport/security semantics differ from AISP/PISP/CBPII.

## Mock data

The backend seeds deterministic but substantial data on every container start:

- 8 customers
- 20 accounts across current, savings and credit-card products
- 500+ booked/pending transactions
- balances in BRL, USD and EUR
- beneficiaries
- scheduled payments
- payment initiations with idempotency support
- Confirmation of Funds responses based on the live in-memory balance

No real customer data is used.

## Security artifacts

`./scripts/generate-certs.sh` creates:

- local root CA
- APIM server certificate with SANs `localhost`, `wso2apim`
- IS server certificate with SANs `localhost`, `wso2is`
- TPP transport certificate with clientAuth EKU
- PKCS#12 server keystores
- shared JKS/PKCS#12 trust material for cross-product TLS and TPP trust
- TPP private key/cert for the demo client

The files under `.state/certs/` are disposable demo credentials and are gitignored.

## Open Banking artifact distribution modes

Open Banking Accelerator 4.0 uses two different packaging mechanisms in this demo:

1. **Identity Server** gets `wso2-fsiam-accelerator-4.0.0.zip`.
2. **API Manager** gets `fs-apim-mediation-artifacts-1.0.0.zip` from WSO2's Financial Services APIM Mediation Policies project. It is **not** installed from a `wso2-fsam-accelerator-4.0.0.zip`, because the 4.0 release moved APIM runtime enforcement to mediation policies.

The clean-install default downloads the official IAM Accelerator release:

```bash
ACCELERATOR_SOURCE_MODE=release
FS_ACCELERATOR_GIT_REF=v4.0.0
```

To build the IAM Accelerator from source instead:

```bash
ACCELERATOR_SOURCE_MODE=source
FS_ACCELERATOR_GIT_REF=v4.0.0
```

The source build runs inside Docker with Java 17, Maven, Node and npm. Node/npm are required by the Accelerator's React/self-care portal modules. The build command is `mvn clean install`; the stale `-P solution` invocation is intentionally not used.

For an air-gapped/controlled environment, pre-place the IAM artifact and mediation artifact in `dist/` and configure local modes:

```bash
ACCELERATOR_SOURCE_MODE=local
APIM_POLICIES_SOURCE_MODE=local
```

Required files:

```text
wso2-fsiam-accelerator-4.0.0.zip
fs-apim-mediation-artifacts-1.0.0.zip
```

By default the APIM mediation artifact is built from the pinned WSO2 tag `v1.0.0` using Dockerized Maven:

```bash
APIM_POLICIES_SOURCE_MODE=source
FS_APIM_MEDIATION_POLICIES_GIT_REF=v1.0.0
```

## Design note: why the bootstrap has hard gates

A container being `Up` is insufficient. `scripts/verify.sh` checks:

- APIM management surface
- IS OIDC/JWKS surface
- Financial Services consent surface (must not be a 404)
- API publication/deployment state
- Key Manager integration state
- mock backend health/data volume
- TLS trust and mTLS material
- presence of Financial Services mediation-policy resources installed into APIM

This is deliberate because the requested APIM 4.7 / IS 7.3 pairing is newer than the Accelerator 4.0 published compatibility matrix.

## Production differences

This repository is a **technical demo**, not a production topology. A production bank should additionally use HA/distributed APIM and IS patterns, managed databases, HSM/KMS-backed keys, enterprise PKI/eIDAS or local directory certificates, WAF/ingress, network segmentation, SIEM/APM, secrets management, backup/DR, hardened cipher policy, vulnerability management and documented operational/compliance controls.

## Repository layout

```text
.
├── apis/                       OpenAPI definitions imported into APIM
├── backend/                    Go mock bank backend
├── bootstrap/                  APIM/IS provisioning automation
├── config/                     APIM, IS and MySQL configuration
├── demo/                       TPP/e2e demo scripts
├── docker/                     Custom WSO2 + helper Dockerfiles
├── dist/                       IAM Accelerator, APIM mediation artifact and dependency inputs
├── scripts/                    startup, DB, cert and verification automation
├── docker-compose.yml
└── start.sh
```

See `docs/ARCHITECTURE.md`, `docs/DEMO-STORY.md`, `docs/COMPATIBILITY.md` and `docs/TROUBLESHOOTING.md` before presenting the demo.
