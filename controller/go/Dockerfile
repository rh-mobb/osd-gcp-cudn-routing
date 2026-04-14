# Multi-stage build for the BGP routing controller (controller-runtime).
# Builder: UBI 9 + AppStream go-toolset RPM (matches go.mod; ubi9/go-toolset:9.5 image can lag Go).
# Runtime: UBI Minimal + CA bundle (TLS to GCP/K8s APIs).
FROM registry.access.redhat.com/ubi9/ubi:latest AS builder
USER root
RUN yum install -y go-toolset \
    && yum clean all \
    && rm -rf /var/cache/dnf /var/lib/dnf/history.* /var/log/dnf*.log 2>/dev/null || true
WORKDIR /workspace
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /manager ./cmd/main.go

FROM registry.access.redhat.com/ubi9/ubi-minimal:9.5
RUN microdnf -y install --nodocs ca-certificates \
    && microdnf clean all \
    && rm -rf /var/cache/dnf /var/lib/dnf/history.* /var/log/dnf*.log /var/log/hawkey.log 2>/dev/null || true
WORKDIR /
COPY --from=builder /manager /manager
RUN chmod 0755 /manager && chown 65532:65532 /manager
USER 65532:65532
ENTRYPOINT ["/manager"]
