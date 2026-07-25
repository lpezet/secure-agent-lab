FROM mitmproxy/mitmproxy:12.2.2

USER root
RUN pip install --no-cache-dir requests cachetools

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# audit.py is baked in (unlike addons/, which is bind-mounted) so any addon
# can `import audit` for the shared JSONL writer regardless of load order.
COPY audit.py /opt/agent-proxy/audit.py
ENV PYTHONPATH=/opt/agent-proxy

CMD ["/entrypoint.sh"]
