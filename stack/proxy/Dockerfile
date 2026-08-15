FROM mitmproxy/mitmproxy:12.2.2

USER root
RUN pip install --no-cache-dir requests cachetools

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# audit.py and hostmatch.py are baked in (unlike provider addons, which are
# bind-mounted) so any addon can `import audit` / `import hostmatch` for the
# shared JSONL writer and host matcher regardless of load order.
COPY audit.py /opt/agent-proxy/audit.py
COPY hostmatch.py /opt/agent-proxy/hostmatch.py
ENV PYTHONPATH=/opt/agent-proxy

# The two base addons are baked in for a stronger reason: they are controls the
# deployment does not get to choose, so they must not depend on a deployment
# having copied a file. NOT into /addons — a deployment's bind mount replaces
# that directory wholesale, which is exactly how a stack could run with no
# internal-host block at all. entrypoint.sh loads these first, then whatever is
# mounted at /addons.
COPY addons/000_policy.py addons/001_allowlist.py /opt/agent-proxy/addons/

CMD ["/entrypoint.sh"]
