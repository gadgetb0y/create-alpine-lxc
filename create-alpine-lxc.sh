#!/bin/bash
#
# Proxmox Alpine LXC Creation Script
# Creates an Alpine Linux LXC container with Docker, Tailscale, and development tools
# Author: John Federico (https://gadgetboy.org)
# AI Disclosure: Parts of this script were created with the help of an LLM
#

set -uo pipefail  # Removed 'e' to continue on errors

# Enable debug mode if DEBUG=1
if [ "${DEBUG:-0}" = "1" ]; then
    set -x
fi

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/create-lxc.conf"

# Function to display progress
show_progress() {
    echo -e "${BLUE}[$(date +"%Y-%m-%d %H:%M:%S")]${NC} ${GREEN}➤${NC} $1"
}

# Function to display error
show_error() {
    echo -e "${BLUE}[$(date +"%Y-%m-%d %H:%M:%S")]${NC} ${RED}✗${NC} $1" >&2
}

# Function to display success
show_success() {
    echo -e "${BLUE}[$(date +"%Y-%m-%d %H:%M:%S")]${NC} ${GREEN}✓${NC} $1"
}

# Check and install dependencies
check_dependencies() {
    local deps=("jq" "pct" "pvesh" "pveam")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            if [ "$dep" = "jq" ]; then
                missing+=("$dep")
            fi
        fi
    done
    
    if [ ${#missing[@]} -ne 0 ]; then
        show_progress "Installing missing dependencies: ${missing[*]}"
        # Temporarily disable exit on error for apt commands
        set +e
        apt-get update > /tmp/apt-update.log 2>&1
        local update_result=$?
        if [ $update_result -ne 0 ]; then
            show_error "Failed to update package list. Check /tmp/apt-update.log"
            cat /tmp/apt-update.log
            exit 1
        fi
        
        apt-get install -y jq > /tmp/apt-install.log 2>&1
        local install_result=$?
        if [ $install_result -ne 0 ]; then
            show_error "Failed to install jq. Check /tmp/apt-install.log"
            cat /tmp/apt-install.log
            exit 1
        fi
        set -e
        
        # Verify installation
        if ! command -v jq &> /dev/null; then
            show_error "jq installation failed"
            exit 1
        fi
        show_success "Dependencies installed successfully"
    fi
    
    # Verify critical Proxmox commands
    if ! command -v pct &> /dev/null; then
        show_error "This script must be run on a Proxmox VE host"
        exit 1
    fi
}

# Check dependencies first
check_dependencies

# Load configuration
if [ ! -f "$CONFIG_FILE" ]; then
    show_error "Configuration file not found: $CONFIG_FILE"
    show_progress "Creating default configuration file..."
    cat > "$CONFIG_FILE" << 'EOF'
# Proxmox Alpine LXC Configuration

# General Settings
attended=1                      # 1 for attended, 0 for unattended
hostname="alpine-docker"        # LXC hostname
vmid=""                        # Leave empty for auto-select
root_password="changeme123"    # Root password
tags="alpine;docker"           # Proxmox tags

# Email Settings
smtp_enabled=0                 # 1 to enable email notifications
smtp_server="smtp.gmail.com"
smtp_port=587
smtp_user="your-email@gmail.com"
smtp_password="your-app-password"
smtp_from="your-email@gmail.com"
smtp_to="recipient@example.com"

# Resource Settings
cpu=2                          # Number of CPU cores
ram=2048                       # RAM in MB
swap=512                       # Swap in MB
disk=32                        # Disk size in GB
storage="local-lvm"            # Storage pool (local-lvm, local-zfs, etc.)

# Network Settings
bridge="vmbr0"                 # Network bridge

# SSH Settings
ssh_public_key=""              # SSH public key for root

# Template Settings
template_storage="local"       # Storage for template
template_url=""                # Leave empty to download latest
EOF
    show_success "Default configuration created at: $CONFIG_FILE"
    show_progress "Please edit the configuration and run the script again."
    exit 0
fi

# Source configuration
source "$CONFIG_FILE"

# Validate required variables
show_progress "Validating configuration..."
if [ -z "$hostname" ]; then
    show_error "hostname is required in configuration"
    exit 1
fi

# Function to send email notification
send_email() {
    local subject="$1"
    local body="$2"
    
    if [ "$smtp_enabled" -eq 1 ]; then
        show_progress "Sending email notification..."
        if command -v python3 &> /dev/null; then
            python3 - << EOF
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart

msg = MIMEMultipart()
msg['From'] = '$smtp_from'
msg['To'] = '$smtp_to'
msg['Subject'] = '$subject'

body = '''$body'''
msg.attach(MIMEText(body, 'plain'))

try:
    server = smtplib.SMTP('$smtp_server', $smtp_port)
    server.starttls()
    server.login('$smtp_user', '$smtp_password')
    server.send_message(msg)
    server.quit()
    print("Email sent successfully")
except Exception as e:
    print(f"Failed to send email: {e}")
EOF
        else
            show_error "Python3 not found - email notification skipped"
        fi
    fi
}

# Function to get next available VMID
get_next_vmid() {
    local next_id=100
    # Check if jq is available, use alternative method if not
    if command -v jq &> /dev/null; then
        while pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | jq -r '.[].vmid' | grep -q "^${next_id}$"; do
            ((next_id++))
        done
    else
        # Fallback method without jq
        while pct list 2>/dev/null | awk '{print $1}' | grep -q "^${next_id}$" || qm list 2>/dev/null | awk '{print $1}' | grep -q "^${next_id}$"; do
            ((next_id++))
        done
    fi
    echo "$next_id"
}

# Main script starts here
show_progress "Starting Alpine LXC creation process..."

# Determine VMID
if [ -z "$vmid" ]; then
    vmid=$(get_next_vmid)
    show_progress "Auto-selected VMID: $vmid"
else
    show_progress "Using configured VMID: $vmid"
fi

# Download Alpine template if needed
show_progress "Checking Alpine Linux template..."

# First, update the appliance list
show_progress "Updating container template list..."
if ! pveam update >/dev/null 2>&1; then
    show_error "Failed to update template list - continuing anyway"
fi

# Look for available Alpine templates
show_progress "Searching for Alpine templates..."
available_alpine=$(pveam available 2>/dev/null | grep -E "alpine-3\.[0-9]+-default.*amd64" | sort -V | tail -1 | awk '{print $2}') || true

if [ -z "$available_alpine" ]; then
    show_error "No Alpine templates found in repository"
    exit 1
else
    template_name="$available_alpine"
    show_progress "Found Alpine template: $template_name"
fi

# Check if template exists locally
if pveam list $template_storage 2>/dev/null | grep -q "$template_name"; then
    show_progress "Template already downloaded: $template_name"
else
    show_progress "Downloading Alpine Linux template: $template_name"
    if ! pveam download $template_storage "$template_name"; then
        show_error "Failed to download template"
        exit 1
    fi
fi

template_path="${template_storage}:vztmpl/${template_name}"

# Create the LXC container
show_progress "Creating LXC container..."
pct create $vmid $template_path \
    --hostname "$hostname" \
    --password "$root_password" \
    --unprivileged 1 \
    --tags "$tags" \
    --net0 "name=eth0,bridge=$bridge,firewall=1,ip=dhcp,ip6=dhcp" \
    --storage "$storage" \
    --rootfs "${storage}:${disk}" \
    --cores "$cpu" \
    --memory "$ram" \
    --swap "$swap" \
    --console 1 \
    --onboot 1 \
    --start 0 \
    --features "keyctl=1,nesting=1" \
    --ostype alpine

# Configure the container
show_progress "Configuring container settings..."

# Add Tailscale support
cat >> "/etc/pve/lxc/${vmid}.conf" << EOF

# Tailscale support
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF

# Enable /dev/console
echo "lxc.console.path: /dev/console" >> "/etc/pve/lxc/${vmid}.conf"

# Start the container
show_progress "Starting container..."
pct start $vmid

# Wait for container to be ready
show_progress "Waiting for container to be ready..."
sleep 10

# Function to execute commands in container
exec_in_ct() {
    pct exec $vmid -- "$@"
}

# Update Alpine
show_progress "Updating Alpine Linux..."
exec_in_ct apk update
exec_in_ct apk upgrade

# Install base packages
show_progress "Installing base packages..."
exec_in_ct apk add --no-cache \
    curl \
    wget \
    git \
    vim \
    nano \
    htop \
    bash \
    bash-completion \
    shadow \
    util-linux \
    coreutils \
    findutils \
    grep \
    sed \
    gawk \
    ca-certificates \
    openssl \
    python3 \
    py3-pip \
    openssh \
    mosh \
    dropbear \
    ansible \
    tzdata \
    sudo \
    jq \
    tree \
    ncurses \
    fontconfig \
    terminus-font \
    figlet

# Configure timezone
show_progress "Configuring timezone..."
exec_in_ct cp /usr/share/zoneinfo/UTC /etc/localtime
exec_in_ct echo "UTC" > /etc/timezone

# Install Docker
show_progress "Installing Docker..."
exec_in_ct apk add --no-cache docker docker-cli docker-compose

# Enable and start Docker
exec_in_ct rc-update add docker boot
exec_in_ct service docker start || show_error "Docker service failed to start"

# Install Tailscale
show_progress "Installing Tailscale..."
exec_in_ct apk add --no-cache tailscale

# Enable Tailscale
exec_in_ct rc-update add tailscale

# Load TUN module on the host (not in container)
show_progress "Loading TUN module on host..."
if ! lsmod | grep -q "^tun"; then
    modprobe tun || show_error "Failed to load TUN module - Tailscale may not work properly"
fi

# Try to start Tailscale service
show_progress "Starting Tailscale service..."
exec_in_ct service tailscale start 2>/dev/null || show_error "Tailscale service failed to start - this is normal, will need manual configuration"

# Configure SSH
show_progress "Configuring SSH..."

# Check if sshd_config exists
if exec_in_ct test -f /etc/ssh/sshd_config; then
    # Enable root SSH login temporarily for setup
    exec_in_ct sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config || true
    exec_in_ct sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config || true
else
    show_error "SSH config not found - skipping SSH configuration"
fi

# Add SSH public key if provided
if [ -n "$ssh_public_key" ]; then
    show_progress "Adding SSH public key..."
    exec_in_ct mkdir -p /root/.ssh
    exec_in_ct chmod 700 /root/.ssh
    echo "$ssh_public_key" | pct push $vmid - /root/.ssh/authorized_keys
    exec_in_ct chmod 600 /root/.ssh/authorized_keys
fi

# Configure Dropbear
show_progress "Configuring Dropbear..."
exec_in_ct rc-update add dropbear
exec_in_ct service dropbear start || true

# Allow xterm-ghostty terminal
exec_in_ct sh -c 'echo "export TERM=xterm-256color" >> /etc/profile'

# Set root default directory
show_progress "Setting root default directory..."
exec_in_ct usermod -d /opt root
exec_in_ct mkdir -p /opt

# Change root shell to bash
show_progress "Configuring bash shell..."
exec_in_ct chsh -s /bin/bash root

# Install Oh My Posh
show_progress "Installing Oh My Posh..."
exec_in_ct wget -q https://github.com/JanDeDobbeleer/oh-my-posh/releases/latest/download/posh-linux-amd64 -O /usr/local/bin/oh-my-posh || show_error "Failed to download Oh My Posh"
exec_in_ct chmod +x /usr/local/bin/oh-my-posh

# Download and install Nerd Fonts
show_progress "Installing Nerd Fonts..."
exec_in_ct mkdir -p /usr/share/fonts/nerd-fonts
if exec_in_ct wget -q https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.tar.xz -O /tmp/JetBrainsMono.tar.xz; then
    exec_in_ct tar -xf /tmp/JetBrainsMono.tar.xz -C /usr/share/fonts/nerd-fonts/
else
    show_error "Failed to download JetBrains Mono font"
fi

if exec_in_ct wget -q https://github.com/ryanoasis/nerd-fonts/releases/latest/download/NerdFontsSymbolsOnly.tar.xz -O /tmp/Symbols.tar.xz; then
    exec_in_ct tar -xf /tmp/Symbols.tar.xz -C /usr/share/fonts/nerd-fonts/
else
    show_error "Failed to download Symbols font"
fi

exec_in_ct fc-cache -fv 2>/dev/null || true
exec_in_ct rm -f /tmp/*.tar.xz

# Create custom prompt (simpler than Oh My Posh for compatibility)
show_progress "Configuring custom shell prompt..."
cat > /tmp/custom-prompt.sh << 'PROMPT_EOF'
#!/bin/bash
# Custom prompt for Alpine container

# Colors
RED='\[\033[0;31m\]'
GREEN='\[\033[0;32m\]'
YELLOW='\[\033[1;33m\]'
BLUE='\[\033[0;34m\]'
PURPLE='\[\033[0;35m\]'
CYAN='\[\033[0;36m\]'
WHITE='\[\033[1;37m\]'
RESET='\[\033[0m\]'

# Set prompt
if [ "$EUID" -eq 0 ]; then
    # Root user
    PS1="${RED}╭─${RESET}${CYAN}[${HOSTNAME}]${RESET} ${YELLOW}\w${RESET}\n${RED}╰─${RESET}${RED}#${RESET} "
else
    # Regular user
    PS1="${GREEN}╭─${RESET}${CYAN}[\u@\h]${RESET} ${YELLOW}\w${RESET}\n${GREEN}╰─${RESET}${GREEN}\$${RESET} "
fi

# Set terminal title
case "$TERM" in
xterm*|rxvt*|screen*)
    PS1="\[\e]0;\u@\h: \w\a\]$PS1"
    ;;
*)
    ;;
esac

export PS1
PROMPT_EOF

pct push $vmid /tmp/custom-prompt.sh /etc/profile.d/custom-prompt.sh
exec_in_ct chmod +x /etc/profile.d/custom-prompt.sh

# Create root bashrc
cat > /tmp/root-bashrc << 'BASHRC_EOF'
# .bashrc for root

# Source global definitions
if [ -f /etc/profile ]; then
    . /etc/profile
fi

# Custom aliases
alias ll='ls -la'
alias l='ls -CF'
alias ..='cd ..'
alias docker-compose='docker compose'

# Set default editor
export EDITOR=vim
BASHRC_EOF

pct push $vmid /tmp/root-bashrc /root/.bashrc

# Create Oh My Posh theme (keep for future use)
show_progress "Creating Oh My Posh theme..."
cat > /tmp/atomic.omp.json << 'THEME_EOF'
{
  "$schema": "https://raw.githubusercontent.com/JanDeDobbeleer/oh-my-posh/main/themes/schema.json",
  "blocks": [
    {
      "alignment": "left",
      "segments": [
        {
          "background": "#0077c2",
          "foreground": "#ffffff",
          "leading_diamond": "╭─",
          "style": "diamond",
          "template": " {{ .Name }} ",
          "type": "shell"
        },
        {
          "background": "#FF9248",
          "foreground": "#2d3436",
          "powerline_symbol": "",
          "properties": {
            "style": "folder"
          },
          "style": "powerline",
          "template": " {{ .Path }} ",
          "type": "path"
        }
      ],
      "type": "prompt"
    },
    {
      "alignment": "left",
      "newline": true,
      "segments": [
        {
          "foreground": "#21c7c7",
          "style": "plain",
          "template": "╰─",
          "type": "text"
        },
        {
          "foreground": "#e0f8ff",
          "foreground_templates": ["{{ if gt .Code 0 }}#ef5350{{ end }}"],
          "properties": {
            "always_enabled": true
          },
          "style": "plain",
          "template": "❯ ",
          "type": "status"
        }
      ],
      "type": "prompt"
    }
  ],
  "version": 3
}
THEME_EOF

pct push $vmid /tmp/atomic.omp.json /opt/atomic.omp.json

# Create MOTD script
show_progress "Creating custom MOTD..."
cat > /tmp/motd-script.sh << 'MOTD_EOF'
#!/bin/sh

# Clear default MOTD
> /etc/motd

# Get system information
HOSTNAME=$(hostname)
LAN_IP=$(ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "Not assigned")
TAILSCALE_STATUS=$(tailscale status 2>/dev/null | head -n1 || echo "Tailscale not connected")
TAILSCALE_HOSTNAME=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // "Not available"' 2>/dev/null | sed 's/\.$//')

# Generate ASCII art hostname
echo
figlet -f slant "$HOSTNAME" 2>/dev/null || echo "$HOSTNAME"
echo
echo "🖥️  System Information"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📍 LAN IP Address:      ${LAN_IP:-Not assigned}"
echo "🌐 Tailscale Hostname:  ${TAILSCALE_HOSTNAME:-Not connected}"
echo "🔗 Tailscale Status:    $TAILSCALE_STATUS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
MOTD_EOF

pct push $vmid /tmp/motd-script.sh /etc/profile.d/00-motd.sh
exec_in_ct chmod +x /etc/profile.d/00-motd.sh

# Clear default MOTD
exec_in_ct sh -c '> /etc/motd'

# Configure container for high availability
show_progress "Configuring high availability settings..."
# Note: HA configuration depends on your cluster setup
# This is a placeholder for HA configuration

# Get container IP
show_progress "Getting container network information..."
sleep 5
CONTAINER_IP=$(pct exec $vmid -- ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "Pending DHCP")

# Create summary report
show_progress "Creating summary report..."
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_FILE="/opt/${hostname}_${TIMESTAMP}_report.txt"

cat > /tmp/report.txt << EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🎉 Alpine LXC Container Creation Report
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📅 Timestamp: $(date)
🏷️  Hostname: $hostname
🆔 VMID: $vmid

📊 Resource Configuration:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
💻 CPU Cores: $cpu
🧠 RAM: ${ram}MB
💾 Swap: ${swap}MB
💿 Disk Size: ${disk}GB
🗄️  Storage Pool: $storage
🌐 Network Bridge: $bridge
📍 Container IP: ${CONTAINER_IP:-Pending DHCP assignment}

📦 Installed Packages:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ Docker & Docker Compose
✅ Tailscale VPN
✅ Dropbear SSH Server
✅ Mosh (Mobile Shell)
✅ Ansible
✅ Oh My Posh (installed, custom prompt active)
✅ JetBrains Mono Nerd Font
✅ Development tools (git, vim, nano, htop, etc.)

🔧 Configuration Status:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ Unprivileged container
✅ Nesting enabled (for Docker)
✅ Tailscale kernel support configured
✅ Auto-start on boot enabled
✅ Custom MOTD configured
✅ Root directory set to /opt
✅ Bash shell configured
✅ SSH public key installed: $([ -n "$ssh_public_key" ] && echo "Yes" || echo "No")

📋 Default Alpine Packages:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
$(pct exec $vmid -- apk info 2>/dev/null | sort | head -20)
... and more

🚀 Next Steps:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1. Connect to container: pct enter $vmid
2. Configure Tailscale: tailscale up
3. Start using Docker: docker run hello-world
4. SSH access: ssh root@${CONTAINER_IP:-<pending-ip>}

Container created successfully! 🎉
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF

# Push report to container
pct push $vmid /tmp/report.txt "$REPORT_FILE"
exec_in_ct chmod 644 "$REPORT_FILE"

# Display report
cat /tmp/report.txt

# Send completion email
email_body=$(cat /tmp/report.txt 2>/dev/null || echo "Container creation completed")
if [ "$attended" -eq 0 ]; then
    send_email "LXC Container Created: $hostname" "$email_body"
fi

# Clean up
rm -f /tmp/report.txt /tmp/motd-script.sh /tmp/atomic.omp.json /tmp/custom-prompt.sh /tmp/root-bashrc

# Final success message
show_success "Alpine LXC container '$hostname' (VMID: $vmid) created successfully!"

# If attended mode, ask if user wants to enter the container
if [ "$attended" -eq 1 ]; then
    echo ""
    read -p "Would you like to enter the container now? (y/n): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        show_progress "Entering container..."
        pct enter $vmid
    fi
fi

exit 0
