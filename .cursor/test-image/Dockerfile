FROM quay.io/centos/centos:stream9
# Keep rpm only so install-rpm-remote.sh uses the rpm code path (offline-friendly).
RUN mv /usr/bin/dnf /usr/bin/dnf.disabled 2>/dev/null || true \
    && mv /usr/bin/dnf-3 /usr/bin/dnf-3.disabled 2>/dev/null || true \
    && mv /usr/bin/yum /usr/bin/yum.disabled 2>/dev/null || true \
    && command -v rpm
CMD ["sleep", "infinity"]
