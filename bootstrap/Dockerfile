FROM alpine:3.20
RUN apk add --no-cache bash curl jq openssl ca-certificates coreutils
WORKDIR /workspace
COPY bootstrap.sh lib.sh policy-specs/ /opt/bootstrap/
RUN chmod +x /opt/bootstrap/bootstrap.sh
ENTRYPOINT ["/opt/bootstrap/bootstrap.sh"]
