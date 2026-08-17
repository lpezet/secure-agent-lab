FROM mcr.microsoft.com/devcontainers/typescript-node:22

RUN apt-get update && apt-get install -y --no-install-recommends \
    jq \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Runs each installed provider's lab_setup fragment from /etc/agent-setup.d
# before handing off to the command. Baked in rather than mounted: a bank entry
# that ships a fragment is not installed until something runs it, and a
# deployment cannot be expected to supply that mechanism itself.
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && mkdir -p /etc/agent-setup.d
ENTRYPOINT ["/entrypoint.sh"]
CMD ["sleep", "infinity"]
