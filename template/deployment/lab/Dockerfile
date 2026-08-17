# The one image you build yourself: what the agent needs is yours to decide.
#
# This mirrors stack/lab at the tag compose.yaml pins. It is copied rather than
# inherited because there is no published base image — every service in this
# stack builds from source, and a lab image is deployment-specific by nature.
# If you repin compose.yaml, check this against stack/lab/Dockerfile at the new
# tag; scripts/check-drift.sh will tell you when it has moved.
FROM mcr.microsoft.com/devcontainers/typescript-node:22

RUN apt-get update && apt-get install -y --no-install-recommends \
    jq \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Runs each installed provider's lab_setup fragment from /etc/agent-setup.d
# before handing off to the command — compose mounts ./lab/setup.d there. A
# bank entry that ships a fragment is not installed until something runs it.
# Keep this block when you extend the image: dropping it leaves github and gcp
# looking installed and not configured.
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && mkdir -p /etc/agent-setup.d
ENTRYPOINT ["/entrypoint.sh"]
CMD ["sleep", "infinity"]

# Add what the agent actually needs on top. Anything reaching the network from
# here goes through the proxy, so a tool that cannot use an HTTP proxy will not
# work while the lab network is internal — that is the trade, not a bug.
#
# RUN apt-get update && apt-get install -y --no-install-recommends \
#     python3 python3-pip \
#     && rm -rf /var/lib/apt/lists/*
