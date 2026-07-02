# Uploading and Running the Installer via SSH, per Provider

Examples use `install-dspace10.sh`; substitute `install-dspace9.sh` as needed.

## AWS EC2

Default SSH user for Ubuntu AMIs is `ubuntu`; authentication uses the `.pem` key pair chosen at launch.

```bash
# Upload from your machine
scp -i my-key.pem install-dspace10.sh ubuntu@<PUBLIC_IP>:~

# Connect and run
ssh -i my-key.pem ubuntu@<PUBLIC_IP>
sudo bash install-dspace10.sh
```

Alternative: in the AWS Console use **EC2 → Instance → Connect → EC2 Instance Connect** (browser shell), then fetch the script directly:

```bash
wget https://raw.githubusercontent.com/RideepBty/dspace-installer/main/install-dspace10.sh
sudo bash install-dspace10.sh
```

## Microsoft Azure

Default user is whatever you set at VM creation (commonly `azureuser`), with an SSH key or password.

```bash
scp install-dspace10.sh azureuser@<PUBLIC_IP>:~
ssh azureuser@<PUBLIC_IP>
sudo bash install-dspace10.sh
```

Alternative: **Azure Cloud Shell** (portal, `>_` icon) with the CLI:

```bash
az vm run-command invoke -g <RESOURCE_GROUP> -n <VM_NAME> --command-id RunShellScript \
  --scripts "wget -qO /tmp/i.sh https://raw.githubusercontent.com/RideepBty/dspace-installer/main/install-dspace10.sh && ASSUME_YES=1 DB_PASS=... ADMIN_PASS=... ADMIN_EMAIL=you@x.org bash /tmp/i.sh"
```

(Use unattended mode here - `run-command` has no interactive terminal.)

Note: if your VM has no public IP, the Connect pane defaults to the private IP, which is unreachable from your laptop without a VPN or Bastion. Associate a Standard-SKU static public IP with the NIC first (matching the VM's availability zone), and allow TCP 22 in the NSG.

## Google Cloud

GCP manages SSH keys for you via the `gcloud` CLI (your username is derived from your Google account):

```bash
# Upload from your machine
gcloud compute scp install-dspace10.sh <VM_NAME>:~ --zone <ZONE>

# Connect and run
gcloud compute ssh <VM_NAME> --zone <ZONE>
sudo bash install-dspace10.sh
```

Alternative: click **SSH** next to the instance in the Cloud Console (browser shell), then `wget` the script from GitHub as above.

## Any provider (public repo)

```bash
ssh <user>@<PUBLIC_IP>
wget https://raw.githubusercontent.com/RideepBty/dspace-installer/main/install-dspace10.sh
sudo bash install-dspace10.sh
```

## Tip: host key warning after moving an IP

If you reassign a public IP from an old VM to a new one, your next SSH attempt will fail with "REMOTE HOST IDENTIFICATION HAS CHANGED". That's the cached host key of the old machine, not an attack, clear it and reconnect:

```bash
ssh-keygen -R <PUBLIC_IP>
```
