# Metabobank on Docker — User Guide (v4.1)

This folder is everything you need to run Metabobank on your own Linux machine.
You do not need to install Python, MongoDB or R: they all run inside Docker.

---

## 1. What you get

Three services start together:

| Service | What it does | Address |
|---|---|---|
| `metabospark` | the web application you open in a browser | `http://<your-ip>:8090` |
| `mongodb5_client` | the database, ships with preloaded mass-spec data | internal only: `27023`, not published to the host |
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

**Docker 1.13 is not enough.** CentOS 7 ships an ancient `docker` 1.13.1 in the base
repository, and the `docker compose` plugin mechanism only exists from Docker 19.03 on.
If you install `docker-compose-plugin` on such a host it finishes successfully and still
does nothing. Upgrade the engine and CLI together:

```bash
sudo yum remove -y docker docker-common docker-client || true
sudo yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
docker compose version      # must print v2.x
```

If you must keep the engine on 1.13, install the legacy Compose v1 instead
(`sudo yum install -y epel-release && sudo yum install -y docker-compose`, or
`sudo pip install docker-compose==1.29.2`).

The installer accepts all three situations: `docker compose`, a standalone
`docker-compose`, or a plugin binary found on disk and called directly
(`/usr/libexec/docker/cli-plugins/docker-compose`).

If you are not root, either run the commands with `sudo`, or add yourself to the
`docker` group once and log in again:

```bash
sudo usermod -aG docker $USER
```

---

## 3. Install — pick one of the two ways

### Way A: with internet (recommended)

You need **one file only: `start.sh`**. Everything else — `docker-compose.yml`, the three
images and the checksum file — is fetched from `https://www.metabobank.cn/download`
by the script itself, so there is nothing to download by hand and nothing to keep in
sync.

```bash
bash start.sh
```

(If you already have the whole folder, that works too; existing files in the folder are
reused and a different `docker-compose.yml` is backed up rather than overwritten.)

**Anything already in this folder is used as it is.** If all three `.tar.gz` files are
present, no network request is made at all — they are loaded straight from disk. If only
some are present, the missing ones are downloaded and the existing ones skipped.
Downloads are resumable (`curl -C -`), so an interrupted run continues where it stopped.

What happens, and what you will see:

1. `Step 1: checking Docker on this machine` — Docker, Compose and the daemon are checked, and the exact install command is printed if something is missing.
2. `Step 2: checking the ports Metabobank needs` — only 8090 is checked, because the database port is not published to the host; if another program holds 8090 you get a ready-to-paste alternative command.
3. `Step 3: checking free disk space` — free space is compared with the download size before anything is fetched.
4. `Step 4: downloading files` — only the files that are not here yet; they come from `https://www.metabobank.cn/download`. The database image is about 7.6 GB, so this takes a while.
5. `Step 5: verifying the files` — every file is compared with `SHA256SUMS.txt`; a damaged file is reported with the expected and actual checksum.
6. `Step 6: loading images into Docker` — imports the images; several minutes for the 7.6 GB one.

With the files already on disk, steps 3 and 4 disappear and the run says
`All three image files are already in this folder`.

Then it starts the services, waits for the web application to answer, and prints:

```
==================================================================
  Metabobank is running
==================================================================
  Open it in a browser:   http://192.168.1.20:8090
  Data is stored in:      /opt/metabobank/metabobank_data
```

### Way B: no internet (files copied by hand)

Minimum is **four files** — the three images plus the script:

```
metabospark.tar.gz      mongodb5_client.tar.gz      omics.tar.gz
start.sh
```

Two more are optional:

- `docker-compose.yml` — if it is absent, the script writes a standard one (the same
  three services, same ports). Only provide it if you need to change ports, volumes or
  environment variables.
- `SHA256SUMS.txt` — without it the installer prints a warning and continues.
  `MB_STRICT_SUMS=1` turns a missing checksum into a hard error.

With all three images in the folder, a plain run is enough — it never touches the
network:

```bash
bash start.sh
```

`--local` is only a safety switch for when you want to *guarantee* that no network
request is attempted, for example when only some files are present and you do not want
the script trying to fetch the rest:

```bash
bash start.sh --local
```

In that mode a missing image stops the run immediately and names the file.

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

### Recreating a single service

When you change something that only affects one container — a port in
`docker-compose.yml`, a variable in `.env`, a volume — you do not need to take the
whole stack down:

```bash
bash start.sh recreate metabospark      # the web application
bash start.sh recreate rserve           # the R backend
bash start.sh recreate mongodb5_client  # the database
bash start.sh recreate metabospark rserve # several at once
bash start.sh recreate metabospark --with-deps   # also recreate what it depends on
```

To replace all three, `bash start.sh stop` followed by `bash start.sh` does it — there is
no `--all` shortcut. Use `recreate` when containers are already running and you changed
a port or a variable; `start.sh` alone would leave the running ones untouched.

It runs, in effect:

```bash
docker compose -f docker-compose.yml -p <folder> up -d --no-deps --force-recreate <service>
```

Why those flags:

| Flag | Why |
|---|---|
| `--force-recreate` | without it Compose decides "nothing changed" and does nothing, even after you edited a port or a variable |
| `--no-deps` | without it Compose also recreates the services this one depends on, so recreating the web application would restart the database too |
| no `--build` | the images are prebuilt tarballs, there is no Dockerfile on the client |
| no `--pull` | the images are already local; a pull would only add a failure mode |

The data directory and the database contents are untouched: only the named container is
replaced. If you pass several service names, they are recreated in one go.

### `.env` and the database credentials

The web container does not run the application directly — the image's own `start.sh`
starts it, and that script reads these variables:

| Variable | Meaning | Default |
|---|---|---|
| `METABOBANK_DB_HOST` | database address | `mongodb5_client` (compose service name) |
| `METABOBANK_DB_PORT` | database port inside the container | `27023` |
| `METABOBANK_DB_USER` | database account | `docker_user` |
| `METABOBANK_DB_PASS` | database password | `docker@2026` |
| `METABOBANK_DB_AUTH` | authentication database | `admin` |
| `METABOBANK_SYNC_USER` / `METABOBANK_SYNC_PASS` | account used by the web application to sync | `webuser` / `passw0rd` |

Two traps worth knowing:

1. **`127.0.0.1` inside a container means the container itself.** To reuse a `mongod`
   already running on the host (`127.0.0.1:27023`), switch this service to
   `network_mode: host` or point the host at `host.docker.internal`. The default uses the
   compose service name.
2. When the installer writes `.env` it only rewrites the keys it manages — credentials you
   filled in by hand are kept, and the previous file is backed up as
   `.env.bak.<timestamp>`. Earlier versions overwrote the whole file (and your credentials
   with it); that is fixed.

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

The database port is **not** published to the host, so only the web port can clash
with another installation:

```bash
METABOBANK_PORT=18090 bash start.sh
```

The script reports the port actually published by Docker, so always trust the URL
it prints at the end rather than the default.

### If you really need to reach the database from the host

For `mongosh`, Compass or a backup script running on the same server, uncomment the
`ports` entry of `mongodb5_client` in `docker-compose.yml`:

```yaml
    # ports:
    #   - "127.0.0.1:${METABOBANK_DB_PORT:-27023}:27023"
```

`start.sh` detects it: once the port is published again, 27023 is added back to the
port check automatically and the final summary shows the published port. Binding it
to `127.0.0.1:` keeps it off the network — publish it on `0.0.0.0` only if a remote
host must connect, and remember the database has no TLS.

---

## 8. Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| `Docker is not installed` | no Docker on this machine | follow the install commands printed by the script |
| `Docker is installed but not running` | daemon stopped | `sudo systemctl start docker` |
| `Docker Compose cannot be used` and `docker --version` shows 1.13.x | the old engine cannot load CLI plugins, so the installed plugin is silently ignored | upgrade: `sudo yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin && sudo systemctl restart docker`; or install legacy Compose v1 |
| `Port 8090 is already used` | another Metabobank or other software | `METABOBANK_PORT=18090 bash start.sh`, or stop the old one |
| `driver failed programming external connectivity ... port is already allocated` | the web port is held by another container or process; Docker reports it only after the containers are created | `docker ps --format '{{.Names}}\t{{.Ports}}'`, then `docker stop <name>`; or use another web port. The installer checks this before starting and names the owning container. (With the database port unpublished this only concerns 8090) |
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
