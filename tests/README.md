# Test runs

These tools test the installers on fresh virtual machines and record each run the same way.

| File | Purpose |
| --- | --- |
| `record-run.sh` | Runs an installer under `script`, checks the result, and adds one row to `~/dspace-runs/results.csv` |
| `test-matrix.csv` | The planned runs and their labels: 36 cloud runs (Oracle Cloud, IBM Cloud, Akamai), 4 robustness runs on Oracle, and the practice runs |
| `summarize-results.py` | Turns the collected `results.csv` files into Markdown tables |
| `rebuild-log.csv` | Turn-by-turn log for rebuilding the installer with an AI assistant |

## One run

Use a fresh Ubuntu 22.04 or 24.04 VM with 2 vCPUs, 8 GB RAM and at least 40 GB of disk. Run these commands on the VM:

```bash
cloud-init status --wait
command -v tmux >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq tmux; }
curl -fsSL -o record-run.sh https://raw.githubusercontent.com/RideepBty/DSpace-Installer/main/tests/record-run.sh
L=oracle-u2404-d10-r1
tmux new -s $L "sudo bash record-run.sh --label $L --provider oracle --ref main --script install-dspace10.sh; exec bash"
```

The run happens inside tmux, so it survives a dropped connection. Detach with Ctrl+B, then D, and come back with `tmux attach -t <label>`. If you connect from the kitty terminal, first run `sudo apt install -y kitty-terminfo` on the VM; otherwise tmux will not start.

`--provider` names the cloud (`oracle`, `ibm`, `akamai`; `aws`, `azure` and `gcp` also work). record-run.sh also reads each cloud's metadata service to record the VM type and region, but IBM Cloud's is off unless the VM was created with it, so always give `--provider` on a cloud VM.

Other modes (put them inside the tmux quotes in the same way):

```bash
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

`EXTERNAL_IP` is set to the VM's own address in two cases: on a local VM, and when testing a script with `--file`. On a cloud VM, the original installer has to find the address itself, because that detection is part of the test. If a local VM has several addresses (for example VirtualBox NAT plus host-only), record-run.sh uses the one the host can reach and skips VirtualBox's NAT address (10.0.2.x). On Oracle Cloud and IBM Cloud the public address sits on a NAT gateway rather than on the VM, so record-run.sh asks api.ipify.org for it; the installer itself uses checkip.amazonaws.com.

A `--file` script saved on Windows has CRLF line endings, which bash cannot run. record-run.sh converts them to LF and notes this in `env.txt`.

## Each run's folder

Each run gets a folder, `~/dspace-runs/<label>/`, containing:

- `env.txt`: machine and installer details;
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

The tables are printed and also saved to `summary.md` in the results folder. Practice runs (local, and labels ending in `-p1` on the clouds) and AI-rebuild runs are listed separately from the reported cloud runs.
