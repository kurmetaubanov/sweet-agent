# The image of the embedder. A separate container so that its OOM does not drag brain down:
# torch takes gigabytes on a large batch, while exceeding the limit kills
# the container as a whole — let it be its container, and not the agent's.
#
# Debian, and not Alpine: under musl there are no wheels for torch and scikit-learn.
FROM python:3.12-slim

RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch \
    && pip install --no-cache-dir sentence-transformers \
    && useradd --create-home --uid 1000 embedder

# Built from the root of the project: docker build -f embedder/Dockerfile -t sweet-embedder:dev .
COPY embedder/embedder.py /opt/embedder.py

# The weights are downloaded into the home directory of the user; without a volume they will be
# downloaded at every launch of the container (470 MB for e5-small).
ENV HF_HOME=/home/embedder/.cache/huggingface \
    SWEET_EMBED_TRANSPORT=connect \
    PYTHONUNBUFFERED=1

# We create the cache directory in the image and give it to the user BEFORE USER: docker
# copies the contents of the image into a new named volume together with the rights.
# Without this the volume is created empty and root-owned, while the container under uid 1000
# cannot write into it.
RUN mkdir -p /home/embedder/.cache/huggingface && chown -R embedder /home/embedder/.cache

USER embedder
CMD ["python", "-u", "/opt/embedder.py"]
