# Quadlet Container Installer

Simple, dependency-free way to install and manage a set of Quadlet `.container` units on **CentOS Stream 10** (or any systemd + Podman host).
Users can interactively choose which containers to install **or** run it non-interactively for automation.

> Quadlet transforms `.container` unit files into systemd services (e.g., `web.container` → `web.service`) and manages them with `systemctl`.

---

## Features

* ✅ Interactive multi-select installer (no `dialog`, `whiptail`, or `jq` required)
* ✅ Non-interactive mode for scripts/CI
* ✅ Inject a user-chosen install/data path into unit files
* ✅ Installs units to `/etc/containers/systemd/`
* ✅ Runs `systemctl daemon-reload`, enables & starts selected services
* ✅ Can use **local** `.container` files or a **remote manifest** hosted on GitHub
* ✅ Safe backups of any replaced units

---

## Repository Layout

```
.
├── install-quadlets.sh          # main installer (bash only)
├── container-manifest.txt       # optional: list of raw URLs to .container files
└── quadlets/                    # your .container files (example path)
    ├── web.container
    ├── db.container
    ├── cache.container
    ├── metrics.container
    └── other.container
```

> You can keep `.container` files anywhere—just update the manifest or run the installer from the directory that contains them.

---

## Requirements

* `bash`
* `systemd` (`systemctl`)
* `podman` with Quadlet support (on CS10 this is standard)
* `curl` **only** if using a remote manifest URL
* Root privileges (to write to `/etc/containers/systemd/` and manage services)

---

## Quick Start (local files)

Clone the repo and run the installer where your `.container` files live:

```bash
git clone https://github.com/<you>/<repo>.git
cd <repo>

# make executable
chmod +x ./install-quadlets.sh

# run (will discover *.container in current directory)
sudo ./install-quadlets.sh
```

The script will:

1. Ask for an install/data path (defaults to `/opt/containers`).
2. Discover `*.container` files and let you select which to install.
3. Inject your chosen path into placeholders inside the units.
4. Copy them to `/etc/containers/systemd/`, `daemon-reload`, enable & start.

---

## Install From GitHub (manifest mode)

Point the installer at a manifest file (one raw URL per line):

**container-manifest.txt**

```
https://raw.githubusercontent.com/<you>/<repo>/refs/heads/main/quadlets/web.container
https://raw.githubusercontent.com/<you>/<repo>/refs/heads/main/quadlets/db.container
https://raw.githubusercontent.com/<you>/<repo>/refs/heads/main/quadlets/cache.container
https://raw.githubusercontent.com/<you>/<repo>/refs/heads/main/quadlets/metrics.container
https://raw.githubusercontent.com/<you>/<repo>/refs/heads/main/quadlets/other.container
```

Run:

```bash
sudo ./install-quadlets.sh \
  --manifest https://raw.githubusercontent.com/<you>/<repo>/refs/heads/main/container-manifest.txt
```

---

## Selecting Containers

During interactive mode you can enter:

* Numbers: `1,3,5`
* Ranges: `2-4`
* Mix: `1,3-5`
* Exact filenames/globs as listed
* `all`

### Non-interactive examples

Install **all** containers to a custom path:

```bash
sudo ./install-quadlets.sh \
  --manifest https://raw.githubusercontent.com/<you>/<repo>/refs/heads/main/container-manifest.txt \
  --install-dir /srv/containers \
  --non-interactive \
  --select "all"
```

Install just two specific units:

```bash
sudo ./install-quadlets.sh \
  --manifest https://raw.githubusercontent.com/<you>/<repo>/refs/heads/main/container-manifest.txt \
  --non-interactive \
  --select "web.container,db.container"
```

> When using `--non-interactive`, `--select` must match discovered items.

---

## Path Injection (templates)

Inside your `.container` files, use one of these tokens wherever the user-chosen path should be inserted:

* `{{INSTALL_DIR}}`
* `%%INSTALL_DIR%%`

Example snippet:

```ini
[Container]
Volume={{INSTALL_DIR}}/web:/var/www:Z
```

The installer replaces those tokens with the selected path (e.g., `/opt/containers`).

---

## What the Installer Does

1. Creates the chosen install dir if missing (e.g., `/opt/containers`)
2. Backs up any existing units it is about to replace:

   * `/etc/containers/systemd.bak-YYYYMMDD-HHMMSS/`
3. Copies selected `.container` files to:

   * `/etc/containers/systemd/`
4. Runs:

   * `systemctl daemon-reload`
   * `systemctl enable --now <name>.service`

Service names are derived from file names (e.g., `web.container` → `web.service`).

---

## Managing Services

```bash
# Check status
systemctl status web.service

# View logs
journalctl -u web.service -f

# Restart after changes
systemctl daemon-reload
systemctl restart web.service
```

---

## Updating

* **Units changed in Git:** pull latest changes and rerun the installer (it will back up and replace).
* **Changed images:** restart the service; if your unit is configured with `PodmanArgs=--pull=always` or an equivalent pull policy, it will fetch newer images automatically.

---

## Adding New Containers

1. Add a new `.container` file to the repo (e.g., `quadlets/newapp.container`).
2. Use `{{INSTALL_DIR}}`/`%%INSTALL_DIR%%` tokens where you reference host paths.
3. If using manifest mode, append the file’s **raw** GitHub URL to `container-manifest.txt`.
4. Commit & push. Users can reinstall or selectively install the new unit.

---

## Uninstall

```bash
# Stop & disable
sudo systemctl disable --now <name>.service

# Remove the unit
sudo rm -f /etc/containers/systemd/<name>.container

# Reload systemd
sudo systemctl daemon-reload
```

(Optionally remove data in your chosen `INSTALL_DIR` if you no longer need it.)

---

## Troubleshooting

* **“Please run as root”** – You must run the installer with `sudo` to write system units and manage services.
* **`systemctl: command not found`** – Ensure you’re on a systemd host (CentOS Stream 10 uses systemd).
* **SELinux denials** – Units mounting host paths should use `:Z` labels in `Volume=` or set appropriate contexts:

  ```bash
  sudo chcon -R -t container_file_t /opt/containers/yourapp
  ```
* **Ports already in use** – Adjust image args/ports in your `.container` files.
* **Image pull/auth** – Make sure containers can pull required images (registry creds, network access).

---

## Security Best Practices

* Prefer pinning images by **digest** (`image@sha256:...`) where possible.
* Review `.container` files before installing.
* Scope host mounts to the minimal directories needed.
* Keep Podman and the OS up to date.

---

## Contributing

PRs welcome!

* Follow the structure above.
* Keep `.container` units clean, commented, and tokenized for `{{INSTALL_DIR}}`.
* Update `container-manifest.txt` when adding/removing units exposed via GitHub raw URLs.

---

## License

Choose a license and add it here (e.g., MIT, Apache-2.0). Add a `LICENSE` file at the repo root.

---

## References

* Quadlet docs (systemd generator for Podman)
* `systemctl`, `journalctl`, and `podman` man pages

---

*Happy shipping!*