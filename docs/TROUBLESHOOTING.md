# Troubleshooting

## `Cannot run program "npm"` while building `consentmgr`

This indicates an old copy of the demo attempted to build the full Financial Services Accelerator source with a Maven-only image. The React/self-care portal modules execute npm, so a source build also requires Node/npm.

The corrected repository avoids this on a clean install by downloading the official IAM Accelerator 4.0.0 release (`ACCELERATOR_SOURCE_MODE=release`). If you deliberately select `source`, the startup script now installs Node/npm inside the Dockerized builder before running Maven.

## Build says `4.1.x-SNAPSHOT` while `FS_ACCELERATOR_VERSION=4.0.0`

Do not use `main` for the Accelerator source. The demo pins `v4.0.0`. A migration guard also converts an old `FS_ACCELERATOR_GIT_REF=main` setting to `v4.0.0` when the requested accelerator version is 4.0.0.

## `The requested profile "solution" could not be activated`

The 4.0.0 POM does not define a `solution` profile. The corrected source build uses:

```bash
mvn -B -DskipTests clean install
```

## Why there is no `wso2-fsam-accelerator-4.0.0.zip`

Open Banking Accelerator 4.0 changed the packaging model. The IAM Accelerator ZIP is installed into Identity Server, while API Manager runtime enforcement is supplied through WSO2 Financial Services APIM Mediation Policies. The startup therefore prepares `fs-apim-mediation-artifacts-1.0.0.zip`, copies its runtime JARs and custom sequences into APIM, and later uploads its policy `.j2` files through the Publisher API.

## `merge.sh`: `Product home is: /` / invalid Carbon product path

Symptom during the `wso2is` Docker image build:

```text
Product home is: /
Accelerator home is: /home
ERROR:specified product path is not a valid carbon product path
```

Cause: `wso2-fsiam-accelerator-4.0.0/bin/merge.sh` determines the product and
accelerator homes from the **current working directory**. Invoking the script by
absolute path from Docker's default working directory is therefore not equivalent
to WSO2's documented installation procedure.

The Dockerfile now changes to the accelerator `bin` directory first and executes
`bash ./merge.sh` there:

```dockerfile
RUN set -eux; \
    cd "${WSO2_SERVER_HOME}/wso2-fsiam-accelerator-${FS_ACCELERATOR_VERSION}/bin"; \
    bash ./merge.sh
```

After updating, rebuild the IS image (or simply run `./start.sh` again). Docker can
reuse the already-built APIM mediation-policy and backend layers.
