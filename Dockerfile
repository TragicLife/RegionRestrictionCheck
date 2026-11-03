FROM alpine:3.20

COPY check.sh /check.sh

RUN chmod +x /check.sh && \
    apk add --no-cache curl wget bash jq

ENTRYPOINT ["/bin/bash", "-l", "-c", "/check.sh"]
