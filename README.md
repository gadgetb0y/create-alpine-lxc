# Alpine LXC Creation Script for Proxmox VE

This opinionated script automates the creation of Alpine Linux LXC containers on Proxmox with Docker, Tailscale, and development tools pre-installed.

## 🚀 Features

- **Automated Alpine Linux LXC creation** with latest template
- **Docker & Docker Compose** pre-installed and configured
- **Tailscale VPN** support with kernel configuration
- **Oh My Posh** with Atomic theme and Nerd Fonts
- **Development tools**: git, vim, ansible, mosh, etc.
- **Custom MOTD** with system information
- **Email notifications** for unattended installations
- **Flexible configuration** via external config file
- **High availability** and backup ready

## 📋 Requirements

- Proxmox VE 7.x or 8.x
- Root access on Proxmox host
- Internet connection for package downloads
- Python3 (for email notifications)
- Sufficient storage and resources

## 🛠️ Installation

1. Copy the script to your Proxmox host:
```bash
wget https://git.gadgetboy.org/Homelab/create-alpine-lxc/raw/branch/main/create-alpine-lxc.sh
chmod +x create-alpine-lxc.sh
```

2. **Review the script then** run it once to generate the configuration file:
```bash
./create-alpine-lxc.sh
```

3. Edit the configuration file:
```bash
nano create-lxc.conf
```

4. Run the script again to create your container:
```bash
./create-alpine-lxc.sh
```

## ⚙️ Configuration Options

### Essential Settings

| Variable | Description | Default |
|----------|-------------|---------|
| `attended` | Interactive (1) or unattended (0) mode | `1` |
| `hostname` | Container hostname | `alpine-docker` |
| `vmid` | Container ID (empty for auto) | `""` |
| `root_password` | Root password | `changeme123` |
| `tags` | Proxmox tags | `alpine;docker` |

### Resource Settings

| Variable | Description | Default |
|----------|-------------|---------|
| `cpu` | Number of CPU cores | `2` |
| `ram` | RAM in MB | `2048` |
| `swap` | Swap in MB | `512` |
| `disk` | Root disk size in GB | `32` |
| `storage` | Storage pool name | `local` |

### Network Settings

| Variable | Description | Default |
|----------|-------------|---------|
| `bridge` | Network bridge | `vmbr0` |
| `ssh_public_key` | SSH public key for root | `""` |

### Email Settings (Unattended Mode)

| Variable | Description | Default |
|----------|-------------|---------|
| `smtp_enabled` | Enable email notifications | `0` |
| `smtp_server` | SMTP server address | `smtp.gmail.com` |
| `smtp_port` | SMTP port | `587` |
| `smtp_user` | SMTP username | `""` |
| `smtp_password` | SMTP password | `""` |

## 📦 Included Software

### System Tools
- Alpine Linux (latest)
- Bash & Bash completion
- Core utilities (curl, wget, git, vim, nano, htop)
- Python 3 & pip

### Container & Virtualization
- Docker CE
- Docker Compose
- Container networking support

### Network Tools
- Tailscale VPN
- Dropbear SSH server
- OpenSSH client
- Mosh (mobile shell)

### Development Tools
- Ansible
- Git
- Oh My Posh (modified Atomic theme)
- JetBrains Mono Nerd Font
- Various text editors

## 🎨 Features Details

### Custom MOTD
The container displays a custom message of the day showing:
- ASCII art hostname
- LAN IP address
- Tailscale hostname and status
- System information

### Oh My Posh Theme
The Atomic theme provides:
- Git status integration
- Execution time tracking
- Multiple programming language indicators
- Battery status (if applicable)
- Current time display

### Docker Configuration
- Docker daemon auto-starts on boot
- Nesting enabled
- Proper cgroup configuration

### Tailscale Support
- Kernel modules configured
- TUN device support
- Ready for `tailscale up` command

## 🔧 Post-Installation Steps

1. **Enter the container**:
   ```bash
   pct enter <VMID>
   ```

2. **Configure Tailscale**:
   ```bash
   tailscale up
   ```

3. **Test Docker**:
   ```bash
   docker run hello-world
   ```

4. **Check the configuration report**:
   ```bash
   cat /opt/<hostname>_*_report.txt
   ```

## 🔒 Security Considerations

- **Change the default root password immediately**
- Configure SSH key authentication
- Consider disabling password authentication
- Set up nominal firewall rules
- Keep the system updated

## 🐛 Troubleshooting

### Container Won't Start
- Check Proxmox logs: `journalctl -u pve-container@<VMID>`
- Verify storage has enough space
- Check if VMID is already in use

### Network Issues
- Verify bridge configuration
- Check DHCP server availability
- Ensure firewall allows container traffic

### Docker Issues
- Verify nesting is enabled in container options
- Check Docker daemon logs: `docker logs`
- Ensure cgroup configuration is correct

### Tailscale Issues
- Check if TUN device exists: `ls /dev/net/tun`
- Verify kernel module: `lsmod | grep tun`
- Check Tailscale logs: `tailscale status`

## 📝 Advanced Usage

### Multiple Storage Pools
Use different storage for different components:
```bash
storage="local"      # For root filesystem
template_storage="local" # For templates
```

### High Availability
Configure HA in a Proxmox cluster:
```bash
# In create-lxc.conf (uncomment and configure)
ha_enabled=1
ha_group="ha-group-1"
```

## 🤝 Contributing

Feel free to submit issues, fork the repository, and create pull requests for any improvements.

## 📄 MIT License

This script is provided as-is without warranty. Use at your own risk.

**Always test in a non-production environment first!**

## 🙏 Acknowledgments

- [Proxmox team](https://www.proxmox.com/en/about/about-us/company)
- [Alpine Linux](https://www.alpinelinux.org/about/) maintainers
- [Jan De Dobbeleer](https://github.com/sponsors/JanDeDobbeleer), creator of [Oh My Posh](https://github.com/JanDeDobbeleer/oh-my-posh)


