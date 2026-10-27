# Troubleshooting

Failures observed on real installs, with diagnosis and fix. Paths assume the defaults (`/opt/tomcat`, `/opt/solr`, `/dspace`, service user `dspace`).

## UI shows "500 Service unavailable"

The UI process is running but cannot get a valid answer from the REST API. Follow the steps through, the first failing step is your culprit:

1. **Backend up locally?**
   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/server/api
   ```
   `000` → Tomcat is down or still starting; see sections below.

2. **API reachable on the public IP?** (This is the exact call the UI's server-side renderer makes.)
   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' http://<PUBLIC_IP>:8080/server/api
   ```
   Works on localhost but not here: the cloud firewall isn't allowing port 8080 (and probably 4000). Add the security group / NSG / VPC rule.

3. **Both return 200 but the 500 persists?** The UI likely started before the backend was healthy, or `config.prod.yml` holds a stale IP (did an ephemeral IP change after a stop/start?). Check the config, then:
   ```bash
   sudo -u dspace bash -c 'export NVM_DIR=~dspace/.nvm; . $NVM_DIR/nvm.sh; pm2 restart dspace-ui'
   ```

## Tomcat fails: `Attribute "URIEncoding" was already specified`

```
SAXParseException; systemId: file:/opt/tomcat/conf/server.xml; ...
Attribute "URIEncoding" was already specified for element "Connector".
```

Cause: an older version of the installer appended `URIEncoding="UTF-8"` to the connector on every run, so re-running duplicated the attribute and made the XML invalid. Current scripts guard against this, but existing installs may be corrupted.

Fix: find the duplicates, they may be on different lines of the same `<Connector>` element:

```bash
sudo grep -n 'URIEncoding' /opt/tomcat/conf/server.xml
```

Delete all but one occurrence (e.g. if the extra one is on line 74):

```bash
sudo sed -i '74s| *URIEncoding="UTF-8"||' /opt/tomcat/conf/server.xml
sudo systemctl reset-failed tomcat && sudo systemctl restart tomcat
```

## API returns 000 right after a Tomcat restart

Not necessarily an error. The DSpace backend takes 1-3 minutes to initialize after Tomcat starts (watch for the Spring Boot banner in `/opt/tomcat/logs/catalina.out`). Poll until it flips to 200:

```bash
watch -n 5 "curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/server/api"
```

If `systemctl status tomcat` says `failed` rather than `active`, read the log instead:

```bash
sudo tail -50 /opt/tomcat/logs/catalina.out
```

## Solr cores fail to load: `ClassNotFoundException: ...ICUFoldingFilterFactory`

The `search`, `qaevent`, and `suggestion` cores need Lucene's ICU analyzers, which recent Solr 9.x binaries don't bundle. The installer stages `lucene-analysis-icu` and `icu4j` jars into `/opt/solr/server/solr/lib` and sets `-Dsolr.config.lib.enabled=true` (required for Solr 9.8+) in the systemd unit. If cores are missing:

```bash
curl -s 'http://localhost:8983/solr/admin/cores?action=STATUS' | grep -o '"name":"[a-z]*"'
ls /opt/solr/server/solr/lib/
sudo grep SOLR_OPTS /etc/systemd/system/solr.service
sudo tail -50 /opt/solr/server/logs/solr.log
```

All six cores (`authority, oai, qaevent, search, statistics, suggestion`) should be listed. The jar versions must match Solr's bundled Lucene version exactly.

## `pm2: command not found`

pm2 is installed under the dspace user's nvm, which non-interactive shells don't load. Always source nvm explicitly:

```bash
sudo -u dspace bash -c 'export NVM_DIR=~dspace/.nvm; . $NVM_DIR/nvm.sh; pm2 status'
```

## Public IP auto-detection failed

Older installer versions could be poisoned by a provider's metadata service returning an HTML error page (notably: the AWS probe on a GCP VM). Current scripts validate every candidate against an IPv4 regex. Workaround on any version: pass the address explicitly:

```bash
sudo EXTERNAL_IP=<PUBLIC_IP> bash install-dspace10.sh
```

## Angular build dies silently

The kernel OOM killer terminated Node. The installer adds a 4 GB swap file when the system has less swap than that, and sets `--max-old-space-size=4096`, but on very small VMs increase swap or use a bigger instance:

```bash
sudo SWAP_SIZE=8G NODE_HEAP_MB=3072 bash install-dspace10.sh
```

## Everything installed, but the site is unreachable from a browser

In order of likelihood: cloud firewall doesn't allow 8080/4000 (the VM-local UFW is configured by the installer, but the provider's firewall is separate and mandatory); the public IP changed because it's ephemeral (reserve a static one, then update `dspace.server.url`/`dspace.ui.url` in `/dspace/config/local.cfg` and `rest.host` (for DSpace 10 also `ui.baseUrl`) in `config.prod.yml`, rebuild UI config, restart services); or the UI is bound to localhost (the installer binds `0.0.0.0`. Check `ui.host` in `config.prod.yml`).

## The installer stops: "Not enough free disk space"

The check at the start found less free space than the install needs: about 8.5 GB for a first install, plus the swap file it would add and 2 GB for the download cache. Ubuntu Server's installer gives the root volume only part of the disk by default. If the message names an LVM volume group with unused space, add that space with the command it prints, then run the installer again:

```bash
sudo lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
df -h /
```

Otherwise free some space or give the VM a bigger disk. `SKIP_DISK_CHECK=1` skips the check.

## A re-run stops: "The database user 'dspace' already exists ... doesn't match it"

The first install created the PostgreSQL user with a different password. Run the installer again with the first install's password, which is the `db.password` line in `/dspace/config/local.cfg`:

```bash
sudo grep '^db.password' /dspace/config/local.cfg
```

Installers before v1.2.1 failed only after the backend build, at `build.xml:783: Java returned: 1`, and had already written the new password into `/dspace/config/local.cfg`. After such a failure, give the database user the password that file now holds, then run the installer again with it:

```bash
sudo -u postgres psql -c "ALTER ROLE dspace PASSWORD 'the-db.password-value'"
```

## DSpace 10: links and redirects go to localhost:4000

DSpace 10 installs made with installers before v1.2.1 leave the UI's `ui.baseUrl` at its default, `http://localhost:4000`. The browser lands on `localhost:4000` after the end-user agreement, robots.txt lists `http://localhost:4000/sitemap_index.xml`, Google Scholar's `citation_pdf_url` tags point to localhost, and pages are not rendered on the server for visitors. Add the public address under `ui:` in the UI's `config.prod.yml` and restart the UI:

```bash
sudo -u dspace sed -i 's|^  host: 0.0.0.0$|&\n  baseUrl: http://<PUBLIC_IP>:4000|' /home/dspace/dspace-angular-dspace-10.0/config/config.prod.yml
sudo -u dspace -H bash -c '. ~/.nvm/nvm.sh && pm2 restart dspace-ui'
curl -s http://<PUBLIC_IP>:4000/robots.txt | grep Sitemap
```

The last command should now show the public address.
