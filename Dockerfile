# ============================================================
#  Ubuntu 22.04 Server Container
#  - QEMU / KVM (nested virtualisation forced)
#  - OpenSSH server (password from .env)
#  - Tailscale (auth key from .env)
#  - sshx  (web terminal link printed on startup)
# ============================================================
FROM ubuntu:22.04

# ── Build-time args (overridden at runtime via --env-file) ──
ARG DEBIAN_FRONTEND=noninteractive

# ── Environment ─────────────────────────────────────────────
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# ── 1. Base system update & locale ──────────────────────────
RUN apt-get update -y && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
        locales \
        tzdata && \
    locale-gen en_US.UTF-8 && \
    update-locale LANG=en_US.UTF-8

# ── 2. Essential tools ───────────────────────────────────────
RUN apt-get install -y --no-install-recommends \
    wget \
    curl \
    git \
    vim \
    nano \
    htop \
    net-tools \
    iproute2 \
    iputils-ping \
    dnsutils \
    telnet \
    nmap \
    tcpdump \
    lsof \
    strace \
    unzip \
    zip \
    tar \
    gzip \
    bzip2 \
    xz-utils \
    ca-certificates \
    gnupg \
    lsb-release \
    software-properties-common \
    apt-transport-https \
    build-essential \
    cmake \
    python3 \
    python3-pip \
    python3-venv \
    jq \
    tree \
    tmux \
    screen \
    rsync \
    socat \
    netcat-openbsd \
    iptables \
    iptables-persistent \
    ufw \
    sudo \
    bash-completion \
    man-db \
    less

# ── 3. OpenSSH server ────────────────────────────────────────
RUN apt-get install -y --no-install-recommends openssh-server && \
    mkdir -p /var/run/sshd && \
    ssh-keygen -A && \
    # Allow root login with password
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    # Fix PAM for non-interactive login
    sed -i 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' /etc/pam.d/sshd

EXPOSE 22

# ── 4. QEMU / KVM (forced nested virtualisation) ─────────────
RUN apt-get install -y --no-install-recommends \
    qemu-kvm \
    qemu-utils \
    qemu-system-x86 \
    libvirt-daemon-system \
    libvirt-clients \
    bridge-utils \
    virtinst \
    cpu-checker \
    dnsmasq-base \
    ovmf \
    virt-top \
    libguestfs-tools \
    kmod && \
    # Create libvirt image directory
    mkdir -p /var/lib/libvirt/images && \
    # Add root to kvm/libvirt groups
    usermod -aG kvm root || true && \
    usermod -aG libvirt root || true

# Force-load KVM modules for both Intel & AMD at runtime (handled in entrypoint)
# Drop a modprobe config that enables nested=1 for BOTH CPU vendors
RUN mkdir -p /etc/modprobe.d && \
    echo "options kvm_intel nested=1" > /etc/modprobe.d/kvm-intel.conf && \
    echo "options kvm_amd nested=1"   > /etc/modprobe.d/kvm-amd.conf

# ── 5. Tailscale ─────────────────────────────────────────────
RUN curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.noarmor.gpg \
        | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null && \
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.tailscale-keyring.list \
        | tee /etc/apt/sources.list.d/tailscale.list && \
    apt-get update -y && \
    apt-get install -y --no-install-recommends tailscale

# ── 6. sshx (web terminal) ───────────────────────────────────
#    Installed at runtime in entrypoint so it always gets the latest binary.
#    We pre-install curl (already done above).

# ── 7. Cleanup ───────────────────────────────────────────────
RUN apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ── 8. Entrypoint script ─────────────────────────────────────
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
