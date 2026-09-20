FROM python:3.13-slim
RUN pip install --no-cache-dir aiohttp
COPY proxy.py /proxy.py
USER nobody
EXPOSE 2375
CMD ["python", "/proxy.py"]