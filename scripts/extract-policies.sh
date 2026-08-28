#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
D=.state/policies
rm -rf "$D"; mkdir -p "$D"
log "Extracting Financial Services API-level policy templates from the APIM image"
docker rm -f wso2-ob-policy-export >/dev/null 2>&1 || true
docker create --name wso2-ob-policy-export "wso2-ob-demo-apim:${APIM_VERSION:-4.7.0}-fs${FS_ACCELERATOR_VERSION:-4.0.0}" true >/dev/null
docker cp wso2-ob-policy-export:/opt/wso2-ob/policies/. "$D/"
docker rm wso2-ob-policy-export >/dev/null
for f in mtlsEnforcementPolicy.j2 consentEnforcementPolicy.j2 dynamicEndpointPolicy.j2; do
  find "$D" -type f -name "$f" -print -quit | grep -q . || fatal "Financial Services mediation bundle does not contain $f. Compatibility gate failed."
done
