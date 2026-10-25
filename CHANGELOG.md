# Changelog

## v1.2.1 (unreleased)

- Added: an optional download cache. With `DOWNLOAD_CACHE=/var/cache/dspace-installer`, the installer keeps a copy of everything it downloads in that folder and takes it from there on later runs. It covers the Maven, Solr and Tomcat archives (reused only when they match Apache's SHA-512, which is kept with them), the DSpace and dspace-angular source archives, the Maven repository, the npm cache, the Node.js archives nvm downloads, and the apt packages. A library with slow internet can fill the folder once elsewhere and copy it to the server. Off unless set; with it off, the only change is that the two source archives are downloaded by root to `/tmp` and unpacked by the service user.
- Changed: interactive mode always asks for the public address, with the detected address as the default (Enter keeps it), and accepts only an IP address or host name. Before, a detected address was used without asking; on a local VM, the address found through checkip.amazonaws.com belongs to the network's router, not the VM. Unattended runs (`ASSUME_YES=1`) and runs with `EXTERNAL_IP` set behave as before. Interactive mode now asks for four things: the public address, the database password, the admin e-mail and the admin password (each password typed twice); then it asks whether to proceed.
- Changed: dspace-angular's `npm install` no longer downloads the Cypress test runner (`CYPRESS_INSTALL_BINARY=0`). Cypress is one of dspace-angular's development dependencies, used only for its own end-to-end tests; building and running the UI never needs it, so every install now downloads and stores less.
- Added: `tests/record-run.sh --cache` (wrapper 1.2) runs the installer with the download cache and records `cache=yes` and the cache size in `results.csv`. It refuses `--cache` for reported-run labels, and without `--cache` it removes any `DOWNLOAD_CACHE` left in the environment. A `results.csv` started by wrapper 1.1 gets the new columns and keeps its rows.
- Changed: `tests/` now plans local VirtualBox runs. `test-matrix.csv` lists 8 reported runs and 4 practice runs. `summarize-results.py` reports the runs the matrix marks as reported on any machine, never counts a `cache=yes` run as reported, and takes step times from passing fresh installs only. `tests/README.md` describes local runs first, and cloud VMs as an option.
- Note on v1.2.0: its release page carries the changed installers as attachments, but its tag points at commit 5882d0e, whose installers don't yet have the changes listed under v1.2.0. v1.2.1 is the first tag whose source code has them.

## v1.2.0 (2026-10-15)

- Fixed: in unattended mode (`ASSUME_YES=1`) a generated admin or database password was never shown. Generated passwords are now saved to `/root/dspace-credentials.txt` (readable by root only) before anything is installed, and an unattended re-run reuses them instead of generating new ones that would no longer match the database and the admin account.
- Added: Maven, Solr and Tomcat are downloaded from Apache's CDN first, with archive.apache.org as the fallback, and each file is checked against Apache's published SHA-512 before it is unpacked. In a test on 13 October 2026 the archive served Solr 9.10.1 at about 35 KB/s.
- Added: every run is logged to `/var/log/dspace-installer.log` (readable by root only). If the installer stops, it prints the exit code and where the log is.
- Fixed: curl is installed before the public-address detection, which needs it. On images without curl the detection failed, and an unattended run used `localhost`.
- Changed: Maven builds with `-B -ntp` instead of `-B -q`, so the long build shows its progress.
- Added (13 October 2026): on Ubuntu images that keep UFW off and reject other ports with iptables, as on Oracle Cloud, the installer opens the REST and UI ports in iptables and saves the rules. It no longer installs ufw where netfilter-persistent is present, because Ubuntu 24.04's ufw package removes it. The unused `xmlstarlet` package was dropped.
- Added (13 October 2026): `tests/`, with `record-run.sh` for recorded test runs.
- DSpace sources the installers download, checked 14 October 2026: DSpace/DSpace `dspace-10.0` = 465195f7593cf812fe16efaa1685a9a58823243c, `dspace-9.2` = b3cae7bf301e2a5cdd61e9dcfa9ee6ee595a3872; DSpace/dspace-angular `dspace-10.0` = 7f59f6cf99f0d1fb4b2abe46e9f24a5e1ee01a49, `dspace-9.2` = a54c4f8f382102d36dbde85a747157ba57084d63.

## 2026-07-02

- Added `install-dspace10.sh` for DSpace 10.x: JDK 21 (pinned via update-alternatives), Maven 3.9.x downloaded from Apache archive (distro packages too old), Node 22 default.
- Fixed: Tomcat `server.xml` corruption on re-runs (duplicate `URIEncoding` attribute), the sed is now guarded.
- Fixed: public IP auto-detection on GCP metadata probes now use `curl -f` and every candidate is validated against an IPv4 regex, so one provider's error page can't poison the cascade.
- Fixed: backend webapp copy could nest (`webapps/server/server`) on re-runs are now guarded.
- Restructured repo: per-provider SSH instructions and troubleshooting moved to `docs/`.

## Earlier

- Initial cloud-agnostic release: derived from an Azure-specific DSpace 9 installer; provider-specific IP detection replaced with an AWS/GCP/Azure metadata cascade and generic fallback; firewall guidance generalized to all three providers.
