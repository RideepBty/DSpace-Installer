# DSpace Cloud-Agnostic Installer

Single Bash scripts that install the complete DSpace stack (PostgreSQL, Apache Solr, Apache Tomcat, DSpace backend, Angular frontend under PM2) on a fresh Ubuntu 22.04/24.04 VM on **any cloud provider**: AWS, Azure, GCP, or bare metal.


## Features

- Auto-detects the VM's public IP via AWS/GCP/Azure metadata services, with a generic fallback
- Interactive with sensible defaults, or fully unattended (`ASSUME_YES=1`)
- Idempotent safe to re-run after a mid-flight failure
- All services run as an unprivileged `dspace` user with systemd units (survive reboot)


## Requirements

- Ubuntu 22.04 or 24.04 LTS, root access (sudo)
- 2 vCPU / 8 GB RAM minimum recommended

## Usage

Interactive:

```bash
sudo bash install-dspace10.sh        # or install-dspace9.sh
```

Unattended:

```bash
sudo -E ASSUME_YES=1 DB_PASS=secret ADMIN_PASS=secret ADMIN_EMAIL=you@example.org \
     bash install-dspace10.sh
```

Every setting (versions, ports, users, paths) is an environment variable. See the top of each script for the defaults.

Provider-specific instructions for getting the script onto your VM and running it over SSH: [docs/ssh-per-provider.md](docs/ssh-per-provider.md)

## After installation

Open TCP ports for the REST API (default 8080) and UI (default 4000) in your cloud provider's firewall: EC2 Security Group (AWS), Network Security Group (Azure), or VPC firewall rule (GCP). Reserve a **static public IP**, an ephemeral IP changes on stop/start and breaks the configured URLs.

Health checks (on the VM):

```bash
curl -s -o /dev/null -w 'API:%{http_code}\n' http://localhost:8080/server/api
curl -s -o /dev/null -w 'UI :%{http_code}\n' http://localhost:4000
```

Something broken? See [docs/troubleshooting.md](docs/troubleshooting.md).

## Limitations

HTTP only (put Nginx/Caddy with TLS in front for production); single-VM deployment; outbound email and backups are out of scope.

## License

MIT - see [LICENSE](LICENSE).
