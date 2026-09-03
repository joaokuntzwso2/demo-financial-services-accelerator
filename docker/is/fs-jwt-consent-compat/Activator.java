package com.acme.finlink.fscompat;

import org.osgi.framework.BundleActivator;
import org.osgi.framework.BundleContext;
import org.osgi.framework.ServiceRegistration;

import org.wso2.carbon.identity.oauth2.token.handlers.claims.JWTAccessTokenClaimProvider;

/**
 * Registers the demo Financial Services JWT consent compatibility provider
 * as an IS JWTAccessTokenClaimProvider OSGi service.
 */
public final class Activator implements BundleActivator {

    private ServiceRegistration<?> registration;

    @Override
    public void start(BundleContext context) {

        registration = context.registerService(
                JWTAccessTokenClaimProvider.class.getName(),
                new ConsentJWTAccessTokenClaimProvider(),
                null
        );

        System.out.println(
                "[FINLINK-FS-COMPAT] JWT consent claim provider registered"
        );
    }

    @Override
    public void stop(BundleContext context) {

        if (registration != null) {
            registration.unregister();
        }
    }
}
