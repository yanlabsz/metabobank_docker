# Metabobank on Docker — User Guide (v4.1)

This folder is everything you need to run Metabobank on your own Linux machine.
You do not need to install Python, MongoDB or R: they all run inside Docker.

---

## 1. What you get

Three services start together:

| Service | What it does | Address |
|---|---|---|
| `metabospark` | the web application you open in a browser | `http://<your-ip>:8090` |
| `mongodb5_client` | the database, ships with preloaded mass-spec data | port `27023` (internal / for external tools) |
| `rserve` | the R backend used for omics analysis | internal only |

Your uploaded files, analysis results and the database files are stored in a
normal folder on your disk (`metabobank_data/` next to this script by default),
**not** hidden inside Docker. Stopping or removing containers never deletes them.

---

## 2. Before you start

| Requirement | Minimum | How to check |
|---|---|---|
| Linux with `bash` | CentOS 7.9 / Ubuntu 20.04 or newer | `bash --version` |
| Docker | 20.10 or newer, daemon running | `docker --version` and `docker info` |
| Docker Compose | v2 (`docker compose`) or legacy `docker-compose` | `docker compose version` |
| Free disk | about 25 GB (images + database) | `df -h` |
| Free RAM | 8 GB, 16 GB is comfortable | `free -g` |
| Network | only for the online install | — |

On **Windows**, the same package runs through Docker Desktop; see section 9 for the two
supported setups (WSL 2 recommended, Git Bash workable).

If Docker is missing, install it first:

```bash
# CentOS / RHEL
sudo yum install -y yum-utils
sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo yum install -y docker-ce docker-compose-plugin
sudo systemctl enable --now docker

# Ubuntu / Debian
sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2
sudo systemctl enable --now docker
```

If you are not root, either run the commands with `sudo`, or add yourself to the
`docker` group once and log in again:

```bash
sudo usermod -aG docker $USER
```

---

## 3. Install — pick one of the two ways

### Way A: with internet (recommended)

Copy this folder to the server, then:

```bash
cd metabobank_deploy
bash start.sh
```

What happens, and what you will see:

1. `Step 1: checking Docker on this machine` — Docker, Compose and the daemon are checked, and the exact install command is printed if something is missing.
2. `Step 2: checking the ports Metabobank needs` — 8090 and 27023 are checked; if another program holds them you get a ready-to-paste alternative command.
3. `Step 3: checking free disk space` — free space is compared with the download size before anything is fetched.
4. `Step 4: downloading files` — files come from `https://www.metabobank.cn/download`. The database image is about 7.6 GB, so this takes a while. An interrupted download resumes where it stopped if you run the script again.
5. `Step 5: verifying the files` — every file is compared with `SHA256SUMS.txt`; a damaged file is reported with the expected and actual checksum.
6. `Step 6: loading images into Docker` — imports the images; several minutes for the 7.6 GB one.

Offline mode shows the same phases, minus the download step.

Then it starts the services, waits for the web application to answer, and prints:

```
==================================================================
  Metabobank is running
==================================================================
  Open it in a browser:   http://192.168.1.20:8090
  Data is stored in:      /opt/metabobank/metabobank_data
```

### Way B: no internet (offline bundle)

Put these six files in **one** folder:

```
metabospark.tar.gz        mongodb5_client.tar.gz      omics.tar.gz
docker-compose.yml        SHA256SUMS.txt              start.sh
```

Then:

```bash
bash start.sh --local
```

Offline mode never touches the network. If a file is missing it stops immediately
and tells you which one. `SHA256SUMS.txt` is optional here but recommended: without
it the installer prints a warning and continues, and `MB_STRICT_SUMS=1 bash start.sh --local`
makes a missing checksum a hard error.

### First start takes longer

On the very first start the database imports its data. One or two minutes of
`Waiting for the web application to finish starting` is normal. If it times out
after 90 seconds, the page usually becomes available a minute later anyway.

---

## 4. Open Metabobank

In a browser on the same network:

```
http://<server-ip>:8090
```

On the server itself: `http://127.0.0.1:8090`.

If the page does not open:

| What you see | What it means | What to do |
|---|---|---|
| Connection refused | the web container is not running | `bash start.sh status`, then `bash start.sh logs` |
| Page times out | firewall on the server | open the port: `sudo firewall-cmd --add-port=8090/tcp --permanent && sudo firewall-cmd --reload` |
| Error page from the app | the app cannot reach the database | `bash start.sh logs`; wait for the database, then `bash start.sh restart` |
| Blank page / 404 | you are on the wrong port | check `bash start.sh status` for the published port |

---

## 5. Everyday commands

```bash
bash start.sh status      # which services are running, on which ports
bash start.sh logs        # follow the web application log (Ctrl+C to stop)
bash start.sh stop        # stop everything; your data stays on disk
bash start.sh restart     # stop, then start again
bash start.sh --only-start # start again quickly (images already loaded)
bash start.sh --force     # recreate containers from scratch, data preserved
```

### Upgrading to a newer release

```bash
bash start.sh stop
# replace the .tar.gz files and docker-compose.yml with the new ones
bash start.sh              # online, downloads the new release and loads it
# or
bash start.sh --local      # offline, uses the new files in this folder
```

Your data folder is untouched during an upgrade. Back it up before a major
version change:

```bash
tar -czf metabobank_data_$(date +%F).tar.gz -C "$(dirname "$PWD")" metabobank_data
```

---

## 6. Where your data lives

Default location: `metabobank_data/` in the folder this script sits in.

```
metabobank_data/
├── csv_upload/        uploaded tables
├── spectrum_upload/   uploaded spectra
├── sample_upload/     sample sheets
├── single_upload/     single-compound files
├── tools_upload/      files for the analysis tools
├── download/          files offered for download
├── compound_catche/   compound cache
└── dbs/               the MongoDB data directory
```

To put the data on a bigger disk, keep it outside the installation folder:

```bash
METABOBANK_DATA_DIR=/data/metabobank bash start.sh
```

The setting is written to `.env` in this folder, so later commands reuse it.

---

## 7. Changing ports

If 8090 or 27023 are already taken by another installation:

```bash
METABOBANK_PORT=18090 METABOBANK_MONGO_PORT=37023 bash start.sh
```

The script reports the port actually published by Docker, so always trust the URL
it prints at the end rather than the default.

---

## 8. Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| `Docker is not installed` | no Docker on this machine | follow the install commands printed by the script |
| `Docker is installed but not running` | daemon stopped | `sudo systemctl start docker` |
| `Port 8090 is already used` | another Metabobank or other software | `METABOBANK_PORT=18090 bash start.sh`, or stop the old one |
| `Not enough free disk space` | less than about 2x the download size free | free space, or move the `.tar.gz` files to a bigger disk and use `--local` |
| `Cannot reach the download site` | no route to `www.metabobank.cn` | check with `curl -I https://www.metabobank.cn/download/`, or go offline with `--local` |
| `The file X is damaged or incomplete` | interrupted download or bad copy | `rm -f X && bash start.sh` (download resumes/restarts cleanly) |
| `Docker could not load X` | almost always disk space | `df -h`, free space, run again |
| `did not come up within 90 seconds` | slow first start, database importing | wait a minute, then `bash start.sh status` and `bash start.sh logs` |
| Two installations on one host | containers are named per folder, so they coexist | use different ports for the second one |

Diagnostic information to include when asking for help:

```bash
bash start.sh status
bash start.sh logs
docker compose version
df -h
```

---

## 9. Running on Windows

Yes, it runs on Windows — with one of the two setups below. The images are **Linux**
images, so Docker Desktop must be in Linux-container mode (the default WSL 2 backend);
Windows-container mode cannot run them.

### Option 1 (recommended): Docker Desktop + WSL 2

1. Install Docker Desktop and leave **Use the WSL 2 based engine** enabled.
2. Copy this folder into the Linux filesystem, not onto `C:` — for example
   `\\wsl$\Ubuntu\home\<you>\metabobank_deploy`.
3. In the WSL terminal:

```bash
cd ~/metabobank_deploy
bash start.sh                 # or: bash start.sh --local
```

4. Open `http://localhost:8090` in a Windows browser.

This behaves exactly like the Linux install described above, because it *is* a Linux
install. Keep the folder and the data directory inside WSL (`/home/...`), not under
`/mnt/c`: bind mounts on `C:` are several times slower, which hurts the database.

### Option 2: Git Bash + Docker Desktop

Workable for evaluation or a single user. The script detects Git Bash automatically and
adjusts what it can:

- port checks switch to `netstat -ano`
- `.env` gets a Windows-style path (`C:/metabobank_data`) because Docker Desktop cannot
  mount `/c/...` paths
- the final URL is printed as `http://localhost:<port>`

Steps:

1. Start Docker Desktop and wait until it says *Engine running*.
2. If bash complains about garbled lines, the file has Windows line endings:

```bash
sed -i 's/\r$//' start.sh
```

3. Point the data directory at a Windows path:

```bash
METABOBANK_DATA_DIR=C:/metabobank_data bash start.sh
# or, with the tarballs already in this folder:
METABOBANK_DATA_DIR=C:/metabobank_data bash start.sh --local
```

Two things to know: Docker Desktop must stay running, and the download of the 7.6 GB
database image goes through the WSL 2 disk, so leave enough space on the drive that
WSL 2 uses.

### Not supported

- **Windows containers mode** — the images are Linux; switch Docker Desktop to the
  WSL 2 backend.
- **PowerShell / cmd alone** — there is no bash there, so `start.sh` cannot run. You can
  still do the same work by hand:

```powershell
docker load -i metabospark.tar.gz
docker load -i mongodb5_client.tar.gz
docker load -i omics.tar.gz
docker compose up -d
```

---

## 10. What is in this folder

| File | Purpose |
|---|---|
| `start.sh` | the installer / controller described above |
| `docker-compose.yml` | defines the three services, ports and volumes |
| `SHA256SUMS.txt` | checksums for the downloaded files |
| `docker_packag_release.py` | only for the release engineer: builds, exports, checksums and uploads the packages |

Publishing a new release (maintainers only, needs SSH/GitHub credentials in
environment variables):

```bash
python3 docker_packag_release.py build spark  --version 3.1 --context /var/www/html/Metabobank_client
python3 docker_packag_release.py build mongo5 --version 3.1 --from-container mongodb5_prepared
python3 docker_packag_release.py build omics  --version 3.1 --context /var/www/html/Omics_r43
python3 docker_packag_release.py bundle --version 3.1
MB_SSH_HOST=... MB_SSH_USER=... MB_SSH_PASS=... python3 docker_packag_release.py upload --dest /var/www/html/download
```

The artifact names (`metabospark.tar.gz`, `mongodb5_client.tar.gz`, `omics.tar.gz`)
and image tags (`metabank/metabospark:v<ver>`, `metabank/mongodb5_client:v<ver>`,
`metabank/metabospark-omics:v<ver>`) match exactly what `start.sh` expects, so a
release built this way installs with a single `bash start.sh`.
