package com.acme.finlink.fscompat;

import org.wso2.carbon.identity.oauth2.IdentityOAuth2Exception;
import org.wso2.carbon.identity.oauth2.authz.OAuthAuthzReqMessageContext;
import org.wso2.carbon.identity.oauth2.token.OAuthTokenReqMessageContext;
import org.wso2.carbon.identity.oauth2.token.handlers.claims.JWTAccessTokenClaimProvider;

import java.util.HashMap;
import java.util.Map;

/**
 * Compatibility provider for Financial Services Accelerator 4.0.0 on the
 * IS 7.2 demo baseline.
 *
 * The Accelerator places the consent binding in an internal authorization
 * scope named consent_id<UUID>. APIM Financial Services consent enforcement
 * requires that binding as the signed JWT claim "consent_id".
 *
 * This provider converts the internal scope into the JWT claim and removes
 * that internal scope from the public scope claim.
 */
public final class ConsentJWTAccessTokenClaimProvider
        implements JWTAccessTokenClaimProvider {

    private static final String CONSENT_PREFIX = "consent_id";
    private static final String CONSENT_CLAIM = "consent_id";

    @Override
    public Map<String, Object> getAdditionalClaims(
            OAuthAuthzReqMessageContext context)
            throws IdentityOAuth2Exception {

        return new HashMap<>();
    }

    @Override
    public Map<String, Object> getAdditionalClaims(
            OAuthTokenReqMessageContext context)
            throws IdentityOAuth2Exception {

        Map<String, Object> claims = new HashMap<>();

        if (context == null || context.getScope() == null) {
            return claims;
        }

        String consentId = null;
        StringBuilder visibleScopes = new StringBuilder();

        for (String scope : context.getScope()) {
            if (scope == null || scope.isEmpty()) {
                continue;
            }

            if (scope.startsWith(CONSENT_PREFIX)
                    && scope.length() > CONSENT_PREFIX.length()) {

                consentId = scope.substring(CONSENT_PREFIX.length());
                continue;
            }

            if (visibleScopes.length() > 0) {
                visibleScopes.append(' ');
            }

            visibleScopes.append(scope);
        }

        if (consentId != null && !consentId.isEmpty()) {
            claims.put(CONSENT_CLAIM, consentId);
            claims.put("scope", visibleScopes.toString());
        }

        return claims;
    }
}
