#!/usr/bin/env bash
# ============================================================
#  entrypoint.sh
#  Starts: SSH server | QEMU/KVM | Tailscale | sshx
# ============================================================
set -e

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
BLU='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GRN}[+]${NC} $*"; }
warn() { echo -e "${YEL}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }
head() { echo -e "\n${BLU}══════════════════════════════════════════${NC}"; \
         echo -e "${BLU}  $*${NC}"; \
         echo -e "${BLU}══════════════════════════════════════════${NC}"; }

# ─── Validate required env vars ───────────────────────────────
: "${SSH_PASSWORD:?SSH_PASSWORD must be set in .env}"
: "${TAILSCALE_AUTHKEY:?TAILSCALE_AUTHKEY must be set in .env}"

# ─── 1. Set root SSH password ─────────────────────────────────
head "SSH Server"
echo "root:${SSH_PASSWORD}" | chpasswd
log "Root password configured."

# Re-generate host keys if missing
ssh-keygen -A 2>/dev/null || true

service ssh start && log "OpenSSH started." || warn "SSH may already be running."

# ─── 2. Force QEMU / KVM setup ───────────────────────────────
head "QEMU / KVM"

# Try loading KVM modules (may fail in unprivileged containers – handled gracefully)
if [ -w /dev/kvm ] 2>/dev/null || [ -e /dev/kvm ]; then
    log "/dev/kvm already available."
else
    warn "/dev/kvm not found – attempting to load kernel modules…"
    modprobe kvm          2>/dev/null && log "kvm module loaded."       || warn "Could not load kvm (needs --device /dev/kvm on host)."
    modprobe kvm_intel nested=1 2>/dev/null && log "kvm_intel loaded."  || true
    modprobe kvm_amd   nested=1 2>/dev/null && log "kvm_amd loaded."    || true
fi

# Verify KVM status
if [ -e /dev/kvm ]; then
    log "KVM is ACTIVE (/dev/kvm present)."
    # Check nested virtualisation
    NESTED_INTEL=$(cat /sys/module/kvm_intel/parameters/nested 2>/dev/null || echo "N/A")
    NESTED_AMD=$(cat /sys/module/kvm_amd/parameters/nested   2>/dev/null || echo "N/A")
    log "Nested virt (Intel): ${NESTED_INTEL} | (AMD): ${NESTED_AMD}"
else
    warn "KVM not available. QEMU will run in TCG (software emulation) mode."
    warn "To enable KVM, run the container with:  --device /dev/kvm --privileged"
fi

# Start libvirtd daemon
if command -v libvirtd &>/dev/null; then
    libvirtd --daemon 2>/dev/null && log "libvirtd started." || warn "libvirtd already running or unavailable."
fi

# ─── 3. Tailscale ────────────────────────────────────────────
head "Tailscale"

# Tailscale requires /dev/tun and iptables – enable if possible
mkdir -p /dev/net
[ -e /dev/net/tun ] || (mknod /dev/net/tun c 10 200 && chmod 666 /dev/net/tun) 2>/dev/null || warn "Could not create /dev/net/tun (may already exist)."

# Start the tailscale daemon in the background
tailscaled --state=/var/lib/tailscale/tailscaled.state \
           --socket=/var/run/tailscale/tailscaled.sock \
           --tun=userspace-networking \
           2>/tmp/tailscaled.log &

TAILSCALED_PID=$!
log "tailscaled started (PID ${TAILSCALED_PID})."
sleep 3

mkdir -p /var/run/tailscale

# Authenticate / bring up the interface
if tailscale up \
      --authkey="${TAILSCALE_AUTHKEY}" \
      --hostname="ubuntu-server-docker" \
      --accept-routes \
      --accept-dns \
      2>/tmp/tailscale-up.log; then
    log "Tailscale connected!"
    TS_IP=$(tailscale ip -4 2>/dev/null || echo "pending…")
    log "Tailscale IPv4: ${TS_IP}"
    echo ""
    echo -e "  ${GRN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "  ${GRN}║  SSH via Tailscale:                          ║${NC}"
    echo -e "  ${GRN}║  ssh root@${TS_IP}                    ║${NC}"
    echo -e "  ${GRN}╚══════════════════════════════════════════════╝${NC}"
else
    warn "Tailscale up failed – check /tmp/tailscale-up.log"
    cat /tmp/tailscale-up.log || true
fi

# ─── 4. sshx – web terminal link ─────────────────────────────
head "sshx (Web Terminal)"

log "Installing sshx…"
curl -sSf https://sshx.io/get | sh 2>/dev/null || warn "sshx download failed."

if command -v sshx &>/dev/null; then
    log "Launching sshx and printing link…"
    echo ""
    # Run sshx in background; its output (the URL) is tee'd to both stdout and a log file
    sshx 2>&1 | tee /tmp/sshx.log &
    sleep 5   # give it time to print the URL
    echo ""
    SSHX_URL=$(grep -oP 'https://sshx\.io/s/\S+' /tmp/sshx.log 2>/dev/null | head -1 || echo "see /tmp/sshx.log")
    echo -e "  ${YEL}╔══════════════════════════════════════════════╗${NC}"
    echo -e "  ${YEL}║  sshx WEB TERMINAL LINK:                     ║${NC}"
    echo -e "  ${YEL}║  ${SSHX_URL}  ║${NC}"
    echo -e "  ${YEL}╚══════════════════════════════════════════════╝${NC}"
    echo ""
else
    warn "sshx binary not found after install."
fi

# ─── 5. Summary ───────────────────────────────────────────────
head "Container Ready"
log "All services started. Container is live."
log "──────────────────────────────────────────"
log "  SSH password : ${SSH_PASSWORD}"
log "  SSH port     : 22 (mapped to host via docker-compose)"
log "  Tailscale IP : $(tailscale ip -4 2>/dev/null || echo 'check Tailscale admin')"
log "  sshx link    : ${SSHX_URL:-see /tmp/sshx.log}"
log "──────────────────────────────────────────"

# ─── 6. Keep container alive ─────────────────────────────────
exec tail -f /dev/null
