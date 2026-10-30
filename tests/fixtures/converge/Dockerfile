# A stand-in for a lab VM, for tests/integration/test_role_converge.sh: Ubuntu 24.04 (the
# VMs' release) with systemd as PID 1 and SSH, so roles run over SSH as on a real run.
# Test only. It is never pushed or run anywhere else.
FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852

# The package lists stay, so roles can install with apt as on a VM.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus openssh-server sudo python3 python3-apt nftables \
      ca-certificates curl iproute2 smbclient \
 && echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/ubuntu \
 && chmod 0440 /etc/sudoers.d/ubuntu \
 && systemctl enable ssh

STOPSIGNAL SIGRTMIN+3
# systemd must run as root: it is the init of this stand-in VM.
# trivy:ignore:AVD-DS-0002
USER root
CMD ["/sbin/init"]
