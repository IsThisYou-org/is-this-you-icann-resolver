FROM golang:1.27.4-alpine3.24 AS builder
RUN CGO_ENABLED=0 go install github.com/letsencrypt/unbound_exporter@v0.6.0

FROM alpine:3.24

RUN apk update
RUN apk upgrade

RUN rm -rf /run /tmp
RUN ln -s /dev/shm /run
RUN ln -s /dev/shm /tmp

COPY --from=builder /go/bin/unbound_exporter /usr/local/bin/
RUN chmod 755 /usr/local/bin/unbound_exporter

RUN apk add unbound

RUN rm -f /var/cache/apk/*

COPY etc/inittab /etc/inittab
COPY etc /usr/local/etc/
COPY bin /usr/local/bin/

COPY build.txt /usr/local/etc/build.txt
CMD [ "/usr/local/bin/start_up" ]
