# Security

## Demo-only repository

This repository is a local technical demonstration. It is **not a production
deployment template** and must not be exposed to an untrusted network.

The demo intentionally uses disposable local credentials and relaxed settings,
including:

- `admin/admin` for the WSO2 super administrator;
- `root/root` and `wso2/wso2` for the local MySQL instance;
- the standard demo keystore password `wso2carbon`;
- locally generated CA, server and TPP keys under `.state/certs/`;
- permissive scope / certificate mappings needed to simplify the demo;
- `curl -k` for selected localhost/bootstrap health checks;
- database TLS disabled inside the private Docker demo network;
- broad CORS settings for local API experimentation.

Never reuse these credentials, certificates, keys or settings in a customer,
shared, staging or production environment.

## Network exposure

All host-published Docker ports must remain bound to `127.0.0.1` by default.
Do not change them to `0.0.0.0` or an external interface unless you also
replace the demo credentials and perform a proper security review.

The mock banking backend is intentionally unauthenticated because API Manager
is the public demo boundary. It must therefore remain localhost-only.

## Local secrets and generated material

Do not commit:

- `.env`;
- `.state/`;
- private keys or certificates;
- PKCS#12 / JKS / truststore files;
- generated OAuth tokens, client secrets or bootstrap diagnostics;
- downloaded WSO2 Accelerator, JAR or ZIP artifacts.

The repository `.gitignore` and `scripts/pre-commit-audit.sh` are intended to
block these classes of files.

`start.sh` and `scripts/generate-certs.sh` create local secret material with a
restrictive umask. Treat `.state/certs/ca.key`, `tpp.key`, server keystores and
`.env` as secrets even though the demo credentials themselves are disposable.

## Docker images

The locally built APIM and IS images contain generated demo server private keys
inside their PKCS#12 keystores. **Do not push these locally built images to a
public or shared container registry.** Rebuild with environment-appropriate PKI
if an image must leave the developer workstation.

## Dependency integrity

The demo downloads version-pinned dependencies over HTTPS and builds the APIM
mediation project from a versioned Git tag. For a controlled or production-like
environment, additionally pin container image digests and verify cryptographic
checksums/signatures for downloaded JAR/ZIP artifacts before use.

## Reporting

Do not open a public issue containing real credentials, private keys, customer
data, access tokens or internal environment information.
