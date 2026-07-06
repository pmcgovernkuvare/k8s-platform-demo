FROM alpine:3.20
RUN apk add --no-cache curl bash
COPY loop.sh /loop.sh
RUN chmod +x /loop.sh
ENTRYPOINT ["/bin/sh", "/loop.sh"]
