# DSpace Cloud Installer

Single Bash scripts that install the complete DSpace stack (PostgreSQL, Apache Solr, Apache Tomcat, DSpace backend, Angular frontend under PM2) on a fresh Ubuntu 22.04/24.04 VM on **any cloud provider**: AWS, Azure, GCP, or bare metal.


## Features

- Auto-detects the VM's public IP via AWS/GCP/Azure metadata services, with a generic fallback
- Interactive with sensible defaults, or fully unattended (`ASSUME_YES=1`)
- Optional download cache for repeated installs or slow internet (`DOWNLOAD_CACHE`)
- Idempotent safe to re-run after a mid-flight failure
- All services run as an unprivileged `dspace` user with systemd units (survive reboot)


## Requirements

- Ubuntu 22.04 or 24.04 LTS, root access (sudo)
- 2 vCPU / 8 GB RAM minimum recommended

## Usage

```bash
wget https://raw.githubusercontent.com/RideepBty/dspace-installer/main/install-dspace10.sh
```

Interactive:

```bash
sudo bash install-dspace10.sh        # or install-dspace9.sh
```

It asks for the public address (Enter keeps the detected one), the database password, the admin e-mail and the admin password, then shows the settings and asks before installing.

Unattended:

```bash
sudo -E ASSUME_YES=1 DB_PASS=secret ADMIN_PASS=secret ADMIN_EMAIL=you@example.org \
     bash install-dspace10.sh
```

Every setting (versions, ports, users, paths) is an environment variable. See the top of each script for the defaults.

Provider-specific instructions for getting the script onto your VM and running it over SSH: [docs/ssh-per-provider.md](docs/ssh-per-provider.md)

## Download cache (optional)

For repeated installs, or a server with slow internet, give the installer a folder to keep its downloads in:

```bash
sudo DOWNLOAD_CACHE=/var/cache/dspace-installer bash install-dspace10.sh
```

The first run saves a copy of every download there: the Apache archives, the DSpace and dspace-angular sources, Maven's and npm's packages, Node.js and the apt packages. Later runs take them from the folder; Apache archives are used only if they still match Apache's SHA-512. The installer prints the folder's size at the end.

To install on a server with poor internet, run the installer once with the cache on a machine with good internet, copy the folder onto the server's disk (not just a USB stick, because part of it is handed to the `dspace` user), and run the installer there with `DOWNLOAD_CACHE` pointing at it. A few small downloads still need internet: apt's package lists, nvm's install script, and Node.js's version and checksum lists.

Use only a cache folder you filled yourself or got from someone you trust: apart from the apt packages, which apt checks against Ubuntu's signatures, the installer trusts what it finds there. Delete the folder when you no longer need it.

## After installation

Open TCP ports for the REST API (default 8080) and UI (default 4000) in your cloud provider's firewall: EC2 Security Group (AWS), Network Security Group (Azure), or VPC firewall rule (GCP). Reserve a **static public IP**, an ephemeral IP changes on stop/start and breaks the configured URLs.

Health checks (on the VM):

```bash
curl -s -o /dev/null -w 'API:%{http_code}\n' http://localhost:8080/server/api
curl -s -o /dev/null -w 'UI :%{http_code}\n' http://localhost:4000
```

Something broken? See [docs/troubleshooting.md](docs/troubleshooting.md).

## Limitations

HTTP only (put Nginx/Caddy with TLS in front for production); single-VM deployment; outbound email and backups are out of scope. The installer skips the Cypress test runner, which dspace-angular uses only for its own end-to-end tests; to run those, install it with `npx cypress install` as the `dspace` user in the dspace-angular folder.

## License

MIT - see [LICENSE](LICENSE).
