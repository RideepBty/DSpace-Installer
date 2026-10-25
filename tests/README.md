# Test runs

These tools test the installers on fresh virtual machines and record each run the same way.

| File | Purpose |
| --- | --- |
| `record-run.sh` | Runs an installer under `script`, checks the result, and adds one row to `~/dspace-runs/results.csv` |
| `test-matrix.csv` | The planned runs and their labels: 8 reported runs on local VirtualBox VMs (Ubuntu 22.04 and 24.04, both installers, plus re-run, reboot, interrupted and resumed runs) and the practice runs |
| `summarize-results.py` | Turns the collected `results.csv` files into Markdown tables |
| `rebuild-log.csv` | Turn-by-turn log for rebuilding the installer with an AI assistant |

## One run

Use a fresh Ubuntu Server 22.04 or 24.04 VM with 2 vCPUs, 8 GB RAM and at least 40 GB of disk. In VirtualBox, give it a NAT adapter plus a host-only adapter, install curl and tmux, and take a snapshot named `clean`; restore that snapshot before each run. Run these commands on the VM:

```bash
command -v tmux >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq tmux; }
curl -fsSL -o record-run.sh https://raw.githubusercontent.com/RideepBty/DSpace-Installer/v1.2.1/tests/record-run.sh
sudo -v
L=local-u2404-d10-r1
tmux new -s $L "sudo bash record-run.sh --label $L --ref v1.2.1 --script install-dspace10.sh; exec bash"
```

The run happens inside tmux, so it survives a dropped connection. Detach with Ctrl+B, then D, and come back with `tmux attach -t <label>`. `sudo -v` asks for your password before tmux starts, because some terminals (Windows Terminal among them) garble the first password typed inside tmux. If you connect from the kitty terminal, first run `sudo apt install -y kitty-terminfo` on the VM; otherwise tmux will not start.

Other modes (put them inside the tmux quotes in the same way):

```bash
sudo bash record-run.sh --label NAME --ref main --cache                # practice run with the download cache
sudo bash record-run.sh --label NAME --file ./install.sh               # test a local script
sudo bash record-run.sh --label NAME --ref main --interrupt-after 12   # stop the installer after 12 minutes
sudo bash record-run.sh --label NAME --check                           # checks only, e.g. after a reboot
```

A run passes when all of the following hold:

- the installer exits with code 0;
- the REST API answers 200 on localhost, and also at the public URL DSpace is configured with, which must not be localhost;
- the UI answers 200;
- the admin can log in through the REST API;
- Solr's `search` core is loaded.

Test passwords are generated once per VM, stored in `/root/dspace-test-secrets.env` (readable by root only) and masked in the saved logs.

`EXTERNAL_IP` is set to the VM's own address in two cases: on a local VM, and when testing a script with `--file`. If a local VM has several addresses (for example VirtualBox NAT plus host-only), record-run.sh uses the one the host can reach and skips VirtualBox's NAT address (10.0.2.x). On a cloud VM the installer has to find its address itself, because that detection is part of the test.

A `--file` script saved on Windows has CRLF line endings, which bash cannot run. record-run.sh converts them to LF and notes this in `env.txt`.

## Practice runs with the download cache

Reported runs download everything, as a library's first install would. Practice runs don't need to. With `--cache`, record-run.sh gives the installer `DOWNLOAD_CACHE=/var/cache/dspace-installer`: the installer keeps a copy of every download in that folder and takes it from there the next time. The run is recorded with `cache=yes`, and summarize-results.py never counts it as reported. record-run.sh refuses `--cache` for reported-run labels (ending in `-r1`, `-rerun`, `-reboot`, `-int12` or `-resume`). Without `--cache` it removes any `DOWNLOAD_CACHE` from the installer's environment, and notes in `env.txt` if the folder exists anyway.

Restoring `clean` deletes the folder, so keep it in a second snapshot, `warm`:

1. Restore `clean` and run a practice install with `--cache`. When it passes, the folder is full.
2. Pack it on the VM: `sudo tar -C /var/cache -cf /tmp/dspace-cache.tar dspace-installer && sudo chown $USER /tmp/dspace-cache.tar`, then copy `/tmp/dspace-cache.tar` to the host with scp.
3. Restore `clean`, copy the file back to the VM's `/tmp`, and unpack it: `sudo tar -C /var/cache -xf /tmp/dspace-cache.tar && rm /tmp/dspace-cache.tar`.
4. Shut the VM down and take a snapshot named `warm`.

Restore `warm` before a practice run and `clean` before a reported run. A practice run of the other installer (or Ubuntu release) on `warm` adds what it needs; repeat steps 2 to 4 after it to keep both in `warm`.

## Each run's folder

Each run gets a folder, `~/dspace-runs/<label>/`, containing:

- `env.txt`: machine and installer details, including whether the download cache was used;
- `terminal.log` and `timing.log`: the full output, replayable with `scriptreplay -t timing.log terminal.log`;
- `terminal.txt`: the same output as plain text;
- `stages.csv`: minutes per `==>` step;
- `health.txt`: the check results;
- `result.json`.

## Summary

Copy each VM's `dspace-runs` folder into one folder, then run:

```bash
python3 summarize-results.py ~/dspace-results --matrix test-matrix.csv
```

On Windows, run `py summarize-results.py $HOME\dspace-results --matrix test-matrix.csv` in PowerShell instead.

The tables are printed and also saved to `summary.md` in the results folder. The reported runs are the labels marked `reported=yes` in the matrix, on whatever machine they ran. Practice runs, AI-rebuild runs and any run with `cache=yes` are listed separately; a reported label that used the cache is named at the top so it can be repeated.

## Cloud VMs (optional)

The same commands work on a cloud VM. Wait for `cloud-init status --wait` first, and add `--provider` with the cloud's short name (`oracle`, `ibm`, `akamai`, `aws`, `azure` or `gcp`). record-run.sh also reads each cloud's metadata service to record the VM type and region, but IBM Cloud's is off unless the VM was created with it, so always give `--provider` on a cloud VM. On Oracle Cloud and IBM Cloud the public address sits on a NAT gateway rather than on the VM, so record-run.sh asks api.ipify.org for it; the installer itself uses checkip.amazonaws.com.
