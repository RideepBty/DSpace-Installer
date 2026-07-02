# DSpace 9 Cloud-Agnostic Installer

A single Bash script that installs the complete DSpace 9 stack (PostgreSQL, Apache Solr, Apache Tomcat, DSpace backend, Angular frontend under PM2) on a fresh Ubuntu 22.04/24.04 VM on **any cloud provider** — AWS, Azure, GCP, or bare metal.

## Features

- Auto-detects the VM's public IP via AWS/GCP/Azure metadata services, with a generic fallback
- Interactive with sensible defaults, or fully unattended (`ASSUME_YES=1`)
- Idempotent — safe to re-run after a mid-flight failure
- All services run as an unprivileged `dspace` user with systemd units (survive reboot)


## Requirements

- Ubuntu 22.04 or 24.04 LTS
- 2 vCPU / 8 GB RAM minimum recommended
- Root access (sudo)

## Usage

Interactive:

```bash
sudo bash install-dspace9.sh
```

Unattended:

```bash
sudo -E ASSUME_YES=1 DB_PASS=secret ADMIN_PASS=secret ADMIN_EMAIL=you@example.org \
     bash install-dspace9.sh
```

Every setting (versions, ports, users, paths) is an environment variable — see the top of the script for the full list of defaults.

## Uploading and running on your VM

```bash
ssh <user>@<PUBLIC_IP>
wget https://raw.githubusercontent.com/RideepBty/DSpace9-Installer/main/install-dspace9.sh
sudo bash install-dspace9.sh
```

## After installation

Open TCP ports for the REST API (default 8080) and UI (default 4000) in your cloud provider's firewall:

- **AWS**: EC2 Security Group inbound rules
- **Azure**: Network Security Group rule
- **GCP**: VPC firewall rule

Reserve a **static public IP** — an ephemeral IP changes on stop/start and breaks the configured URLs.

Health checks (on the VM):

```bash
curl -s -o /dev/null -w 'API:%{http_code}\n' http://localhost:8080/server/api
curl -s -o /dev/null -w 'UI :%{http_code}\n' http://localhost:4000
```

## Limitations

HTTP only (put Nginx/Caddy with TLS in front for production); single-VM deployment; outbound email and backups are out of scope.

## License

MIT — see [LICENSE](LICENSE).
