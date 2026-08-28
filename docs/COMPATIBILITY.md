# Compatibility and support position

The repository intentionally combines:

- API Manager 4.7.0
- Identity Server 7.3.0
- Financial Services IAM Accelerator 4.0.0
- Financial Services APIM Mediation Policies 1.0.0

At the time this demo was assembled (2026-08-27), WSO2's published Accelerator 4.0 compatibility documentation lists APIM through 4.6.0 and IS through 7.2.0. Therefore this exact combination must be treated as **not publicly certified by that matrix**.

The repository reduces, but cannot remove, that risk by:

- running the IAM Accelerator's official `merge.sh` on Identity Server;
- using WSO2's versioned Financial Services APIM Mediation Policies artifact on API Manager rather than assuming an APIM Accelerator ZIP exists in the 4.0 packaging model;
- generating database schemas from the exact built product images;
- failing when the MTLS, Consent Enforcement or Dynamic Endpoint policy templates are missing;
- failing when the consent surface resolves to 404;
- verifying the APIM/IS connector and imported APIs;
- keeping product-specific deployment TOMLs under version control so a merge script cannot silently replace the newer base-product configuration with an older template.

For a customer-facing production recommendation, obtain confirmation for the exact product **update levels**, not only the major/minor numbers.
