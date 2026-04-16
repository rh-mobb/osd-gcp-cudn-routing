FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY bgp_routing_controller/ bgp_routing_controller/

ENV PYTHONPATH=/app
USER 1001

ENTRYPOINT ["kopf", "run", "-m", "bgp_routing_controller.main", "--verbose", "--all-namespaces"]
