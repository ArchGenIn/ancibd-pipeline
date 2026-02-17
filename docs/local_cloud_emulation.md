# Local cloud emulation (Multipass + HTCondor + Apptainer)

This repo is designed for a **shared-filesystem HTCondor cluster**: jobs run on execute nodes, but read/write
from shared paths (`DATA_ROOT`, `HDF5_ROOT`, `RUNS_ROOT`) that are visible at the **same absolute paths** on
all nodes.

If you are nervous about testing directly on a real cloud, you can emulate that environment locally on a
single workstation using **Multipass** (VMs), **HTCondor**, and host-mounted “shared filesystem” folders.

The emulator mirrors the cloud conventions:

- Shared “SSD” at `/mnt/ssd_gluster_volume`
- Shared “HDD” at `/mnt/hdd_gluster_volume`
- Repo checkout at `/opt/ancibd-pipeline`

(Locally, these are just host folders mounted into each VM.)

---

## Quickstart checklist

After you finish the setup below, your typical workflow on the **submit VM** (`agi-main`) is:

```bash
cd /opt/ancibd-pipeline
cp config/multipass.env config/local.env  # or edit config/local.env manually
./containers/build.sh

# Build/validate HDF5 inputs
./ancibd-pipeline build-hdf5-condor 20-20
./ancibd-pipeline validate-hdf5 20-20

# Baseline
RUN_ID="$(./ancibd-pipeline new-run baseline)"; export RUN_ID
./ancibd-pipeline baseline 20-20

# Production (DAGMan)
RUN_ID="$(./ancibd-pipeline new-run prod)"; export RUN_ID
./ancibd-pipeline prod 20-20
./ancibd-pipeline check-batch

# Compare
./scripts/compare_outputs.sh \
  /mnt/ssd_gluster_volume/runs/<RUN_BASE>/out/merged \
  /mnt/ssd_gluster_volume/runs/<RUN_PROD>/out/merged
```

---

## 0) Host prerequisites

- Ubuntu host with hardware virtualization available (`/dev/kvm` should exist).
- Sufficient disk space for the VMs and shared folders.

Install Multipass:

```bash
sudo snap install multipass
sudo systemctl enable --now snap.multipass.multipassd.service
multipass version
```

---

## 1) Create the VMs

The sizes below are meant to be “enough to emulate” without consuming too much disk:

```bash
multipass launch 22.04 --name agi-main --cpus 4 --mem 8G --disk 20G

for i in $(seq 1 8); do
  multipass launch 22.04 --name "agie$i" --cpus 2 --mem 8G --disk 15G
done

multipass list
```

Set hostnames inside each VM:

```bash
multipass exec agi-main -- sudo hostnamectl set-hostname agi-main
for i in $(seq 1 8); do
  multipass exec "agie$i" -- sudo hostnamectl set-hostname "agie$i"
done
```

---

## 2) Create host folders that emulate the shared filesystems

Run this on the host (from anywhere):

```bash
export REPO_ROOT="$(pwd)"        # the ancibd-pipeline repo on the host
export MP_SHARED="$HOME/mp-ancibd-shared"

mkdir -p "$MP_SHARED/ssd_gluster_volume" "$MP_SHARED/hdd_gluster_volume"

# “Everything on SSD” (recommended for the emulator)
mkdir -p "$MP_SHARED/ssd_gluster_volume/runs" "$MP_SHARED/ssd_gluster_volume/runs/hdf5_cache" "$MP_SHARED/ssd_gluster_volume/data"

# Optional: if you want to keep large immutable inputs on “HDD”
mkdir -p "$MP_SHARED/hdd_gluster_volume/data"
```

---

## 3) Mount the repo + shared folders into every VM

```bash
for vm in agi-main agie{1..8}; do
  multipass exec "$vm" -- sudo mkdir -p /opt/ancibd-pipeline /mnt/ssd_gluster_volume /mnt/hdd_gluster_volume

  multipass mount "$REPO_ROOT" "$vm":/opt/ancibd-pipeline
  multipass mount "$MP_SHARED/ssd_gluster_volume" "$vm":/mnt/ssd_gluster_volume
  multipass mount "$MP_SHARED/hdd_gluster_volume" "$vm":/mnt/hdd_gluster_volume

done
```

Sanity check on one VM:

```bash
multipass exec agi-main -- bash -lc 'ls -la /opt/ancibd-pipeline | head; df -hT | egrep "ssd_gluster|hdd_gluster"'
```

---

## 4) Install HTCondor and Apptainer in all VMs

Enable `universe` repo and install prerequisites:

```bash
for vm in agi-main agie{1..8}; do
  multipass exec "$vm" -- sudo apt-get update
  multipass exec "$vm" -- sudo apt-get install -y software-properties-common
  multipass exec "$vm" -- sudo add-apt-repository -y universe
  multipass exec "$vm" -- sudo apt-get update
done
```

Install HTCondor using the official installer.

Choose a shared password for the pool:

```bash
PW='no-password'
```

Central manager on `agi-main`:

```bash
multipass exec agi-main -- bash -lc "
  set -euo pipefail
  curl -fsSL https://get.htcondor.org | sudo GET_HTCONDOR_PASSWORD='$PW' /bin/bash -s -- --no-dry-run --central-manager agi-main
"
```

Make `agi-main` also a **submit** node (add `use role:get_htcondor_submit` in the Condor config as needed),
then reconfigure:

```bash
multipass exec agi-main -- sudo condor_reconfig
```

Execute nodes:

```bash
for vm in agie{1..8}; do
  multipass exec "$vm" -- bash -lc "
    set -euo pipefail
    curl -fsSL https://get.htcondor.org | sudo GET_HTCONDOR_PASSWORD='$PW' /bin/bash -s -- --no-dry-run --execute agi-main
  "
done
```

Make the pool agree on filesystem/user domains:

```bash
cat > "$HOME/90-local-domains.conf" <<'CONF'
FILESYSTEM_DOMAIN = multipass
UID_DOMAIN        = multipass
CONF

for vm in agi-main agie{1..8}; do
  multipass transfer "$HOME/90-local-domains.conf" "$vm":/home/ubuntu/90-local-domains.conf
  multipass exec "$vm" -- sudo bash -lc '
    set -e
    install -m 0644 /home/ubuntu/90-local-domains.conf /etc/condor/config.d/90-local-domains.conf
    condor_reconfig
  '
done

multipass exec agi-main -- bash -lc 'condor_status -af Machine FileSystemDomain UidDomain | sort'
```

Install Apptainer everywhere:

```bash
for vm in agi-main agie{1..8}; do
  multipass exec "$vm" -- bash -lc '
    set -euo pipefail
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends software-properties-common ca-certificates
    sudo add-apt-repository -y ppa:apptainer/ppa
    sudo apt-get update
    sudo apt-get install -y apptainer
    apptainer version
  '
done
```

---

## 5) Make VMs resolve each other by name (optional but nice)

```bash
multipass list --format csv | awk -F, 'NR>1 && $3 != "" {print $3, $1}' > "$HOME/mp-hosts.txt"

for vm in agi-main agie{1..8}; do
  multipass transfer "$HOME/mp-hosts.txt" "$vm":/home/ubuntu/mp-hosts.txt
  multipass exec "$vm" -- sudo bash -lc '
    set -e
    sed -i "/^# multipass-nodes$/,/^# end-multipass-nodes$/d" /etc/hosts
    {
      echo "# multipass-nodes"
      cat /home/ubuntu/mp-hosts.txt
      echo "# end-multipass-nodes"
    } >> /etc/hosts
  '
done
```

---

## 6) Slot model: static slots

In the real cloud, you typically see many static slots per machine.
For the emulator, enable the built-in StaticSlots feature on the execute nodes:

```bash
cat > "$HOME/95-slots.conf" <<'CONF'
use FEATURE:StaticSlots
CONF

for vm in agie{1..8}; do
  multipass transfer "$HOME/95-slots.conf" "$vm":/home/ubuntu/95-slots.conf
  multipass exec "$vm" -- sudo bash -lc '
    set -e
    install -m 0644 /home/ubuntu/95-slots.conf /etc/condor/config.d/95-slots.conf
    condor_reconfig
  '
done
```

With the default VM sizes (2 vCPU / 8 GB), this typically yields ~2 slots per execute VM.

> Note: the pipeline submit files in `condor/` request resources that match these emulator defaults.

---

## 7) Configure the pipeline inside the emulator

On `agi-main`:

```bash
multipass exec agi-main -- bash -lc '
  set -e
  cd /opt/ancibd-pipeline
  cp config/multipass.env config/local.env
  sed -n "1,200p" config/local.env
'
```

Edit `config/local.env` if your input templates differ.

### Choosing where data lives

- “Everything on SSD”: set `DATA_ROOT=/mnt/ssd_gluster_volume/data`
- “Inputs on HDD”: set `DATA_ROOT=/mnt/hdd_gluster_volume/data`

The important invariant is that **all nodes see the same absolute paths**.

---

## 8) Build the container image

On `agi-main`:

```bash
multipass exec agi-main -- bash -lc '
  set -e
  cd /opt/ancibd-pipeline
  ./containers/build.sh
  ls -lh containers/*.sif
'
```

---

## 9) Run the workflow

### Build HDF5 (Condor)

```bash
multipass exec agi-main -- bash -lc '
  set -e
  cd /opt/ancibd-pipeline
  ./ancibd-pipeline build-hdf5-condor 20-20
  condor_q
'
```

### Validate HDF5

```bash
multipass exec agi-main -- bash -lc '
  set -e
  cd /opt/ancibd-pipeline
  ./ancibd-pipeline validate-hdf5 20-20
'
```

### Baseline

```bash
multipass exec agi-main -- bash -lc '
  set -e
  cd /opt/ancibd-pipeline
  RUN_ID="$(./ancibd-pipeline new-run baseline)"; export RUN_ID
  ./ancibd-pipeline baseline 20-20
  echo "BASE_RUN_ID=$RUN_ID"
'
```

### Production (DAGMan)

```bash
multipass exec agi-main -- bash -lc '
  set -e
  cd /opt/ancibd-pipeline
  RUN_ID="$(./ancibd-pipeline new-run prod)"; export RUN_ID
  ./ancibd-pipeline prod 20-20
  condor_q
  ./ancibd-pipeline check-batch
  echo "PROD_RUN_ID=$RUN_ID"
'
```

### Compare

```bash
multipass exec agi-main -- bash -lc '
  set -e
  cd /opt/ancibd-pipeline
  ./scripts/compare_outputs.sh \
    /mnt/ssd_gluster_volume/runs/<RUN_BASE>/out/merged \
    /mnt/ssd_gluster_volume/runs/<RUN_PROD>/out/merged
'
```

---

## Troubleshooting

### Jobs are idle (never start)

Most often: resource requests don’t fit available slots.

```bash
condor_q -better-analyze <clusterid>
condor_status -af Name Cpus Memory Disk State Activity | head -n 30
```

In the emulator, execute VMs are small; the submit templates request modest resources,
but if you change VM sizing or slot config you may need to edit:

- `condor/ancibd_batchpair.sub`
- `condor/ancibd_hdf5.sub`

### DAGMan submits but merge runs too early / missing outputs

This should not happen: the DAG declares `PARENT BATCH CHILD MERGE`.
If it does, check that the DAG file under:

- `RUNS_ROOT/<RUN_ID>/condor/batch/batch.dag`

still contains the dependency line and that all expected batchpair jobs are being queued.

### Path confusion

This repo assumes shared, absolute paths.
Inside the emulator, always run commands from:

- `/opt/ancibd-pipeline` (repo root)

and keep `RUNS_ROOT/HDF5_ROOT/DATA_ROOT` under `/mnt/*_gluster_volume/...`.
