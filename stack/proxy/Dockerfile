FROM mitmproxy/mitmproxy:12.2.2

USER root
RUN pip install --no-cache-dir requests cachetools

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# audit.py and hostmatch.py are baked in (unlike addons/, which is
# bind-mounted) so any addon can `import audit` / `import hostmatch` for the
# shared JSONL writer and host matcher regardless of load order.
COPY audit.py /opt/agent-proxy/audit.py
COPY hostmatch.py /opt/agent-proxy/hostmatch.py
ENV PYTHONPATH=/opt/agent-proxy

CMD ["/entrypoint.sh"]
