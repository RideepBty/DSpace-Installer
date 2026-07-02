# Changelog

## 2026-07-02

- Added `install-dspace10.sh` for DSpace 10.x: JDK 21 (pinned via update-alternatives), Maven 3.9.x downloaded from Apache archive (distro packages too old), Node 22 default.
- Fixed: Tomcat `server.xml` corruption on re-runs (duplicate `URIEncoding` attribute), the sed is now guarded.
- Fixed: public IP auto-detection on GCP metadata probes now use `curl -f` and every candidate is validated against an IPv4 regex, so one provider's error page can't poison the cascade.
- Fixed: backend webapp copy could nest (`webapps/server/server`) on re-runs are now guarded.
- Restructured repo: per-provider SSH instructions and troubleshooting moved to `docs/`.

## Earlier

- Initial cloud-agnostic release: derived from an Azure-specific DSpace 9 installer; provider-specific IP detection replaced with an AWS/GCP/Azure metadata cascade and generic fallback; firewall guidance generalized to all three providers.
