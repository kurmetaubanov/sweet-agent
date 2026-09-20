FROM mitmproxy/mitmproxy:11.1.3

# The directory of the CA certificate. A named volume at the first creation inherits the owner
# of this directory from the image — therefore the chown here, otherwise mitmproxy (not root)
# will not be able to write the generated CA there.
RUN mkdir -p /certs && chown -R mitmproxy:mitmproxy /certs

# We do NOT set USER here. The entrypoint of the image starts as root and drops
# privileges itself to the mitmproxy user; if the container has already started under it,
# there is nowhere to switch and the start falls with "failed switching to mitmproxy:
# operation not permitted" — and then everything collapses: the CA is not created, the agent
# has no trusted certificate, and the network (internal) leaves it without an exit.

COPY --chown=mitmproxy:mitmproxy addon.py /addon.py

EXPOSE 8080

# --set confdir=/certs — the CA is generated onto the shared volume, the agent reads it :ro.
CMD ["mitmdump", "--listen-host", "0.0.0.0", "--listen-port", "8080", \
     "--set", "confdir=/certs", "--set", "block_global=false", \
     "--flow-detail", "1", "-s", "/addon.py"]
