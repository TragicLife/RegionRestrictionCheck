FROM alpine:3.24

COPY check.sh /check.sh

RUN chmod +x /check.sh && \
    apk add --no-cache curl wget bash jq openssl

ENTRYPOINT ["/bin/bash", "-l", "-c", "/check.sh"]
