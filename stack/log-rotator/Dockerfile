FROM alpine:3.20

RUN apk add --no-cache logrotate

COPY logrotate.conf /etc/logrotate.d/audit-logs
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && \
    echo '0 * * * * /usr/sbin/logrotate /etc/logrotate.d/audit-logs' > /etc/crontabs/root

CMD ["/entrypoint.sh"]
