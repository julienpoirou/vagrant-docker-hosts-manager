# vagrant-docker-hosts-manager

[![CI](https://github.com/julienpoirou/vagrant-docker-hosts-manager/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/julienpoirou/vagrant-docker-hosts-manager/actions/workflows/ci.yml)
[![CodeQL](https://github.com/julienpoirou/vagrant-docker-hosts-manager/actions/workflows/codeql.yml/badge.svg)](https://github.com/julienpoirou/vagrant-docker-hosts-manager/actions/workflows/codeql.yml)
[![Release](https://img.shields.io/github/v/release/julienpoirou/vagrant-docker-hosts-manager?include_prereleases&sort=semver)](https://github.com/julienpoirou/vagrant-docker-hosts-manager/releases)
[![RubyGems](https://img.shields.io/gem/v/vagrant-docker-hosts-manager.svg)](https://rubygems.org/gems/vagrant-docker-hosts-manager)
[![License](https://img.shields.io/github/license/julienpoirou/vagrant-docker-hosts-manager.svg)](LICENSE.md)
[![Conventional Commits](https://img.shields.io/badge/Conventional%20Commits-1.0.0-%23FE5196.svg)](https://www.conventionalcommits.org)
[![Renovate](https://img.shields.io/badge/Renovate-enabled-brightgreen.svg)](https://renovatebot.com)
[![Total downloads](https://img.shields.io/gem/dt/vagrant-docker-hosts-manager?logo=rubygems&label=downloads)](https://rubygems.org/gems/vagrant-docker-hosts-manager)

Vagrant plugin to **manage custom hostnames** by updating the local `hosts` file (Windows/Linux/macOS) for Docker‑based environments.

- Adds/removes host entries on `vagrant up` / `vagrant destroy`
- Optional **auto‑detect** of a Docker container IP for a single domain
- Safe, idempotent updates: replaces previous entries for configured domains
- Works across platforms (uses `sudo` on Unix, UAC elevation on Windows)

> Requirements: **Vagrant ≥ 2.2**, **Ruby ≥ 3.1**, **Docker (CLI + daemon) for auto‑detect**

---

## Table of contents

- [Why this plugin?](#why-this-plugin)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Vagrantfile configuration](#vagrantfile-configuration)
- [CLI usage](#cli-usage)
- [How it works](#how-it-works)
- [Permissions & OS notes](#permissions--os-notes)
- [Troubleshooting](#troubleshooting)
- [Contributing & Development](#contributing--development)
- [License](#license)

> 🇫🇷 **Français :** voir [README.fr.md](README.fr.md)

---

## Why this plugin?

When working with Docker + Vagrant, you often need **friendly hostnames** (e.g. `app.local`) that resolve to a container IP. Doing this manually in `/etc/hosts` or `C:\Windows\System32\drivers\etc\hosts` is error‑prone and not portable across teammates.

This plugin:
- **Writes** the required entries during `vagrant up`.
- **Cleans** them safely on `vagrant destroy`.
- Can **auto‑resolve** a container IP (`docker inspect`) if you only provide one `domain` and a `container_name`.

---

## Installation

From RubyGems (once published):

```bash
vagrant plugin install vagrant-docker-hosts-manager
```

From source (local path):

```bash
git clone https://github.com/julienpoirou/vagrant-docker-hosts-manager
cd vagrant-docker-hosts-manager
bundle install
rake
vagrant plugin install .    # install from the local gemspec
```

Check it’s available:

```bash
vagrant hosts --help
```

---

## Quick start

### Minimal Vagrantfile (auto‑detect single container IP)

```ruby
Vagrant.configure("2") do |config|
  config.vm.box = "hashicorp/bionic64"

  # Auto-detect the IP of a running Docker container and map it
  # to a single domain (e.g. http://app.local)
  config.docker_hosts.domain         = "app.local"
  config.docker_hosts.container_name = "my_app_container"   # docker ps --format '{{.Names}}'
end
```

- On `vagrant up`, the plugin runs
  `docker inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" my_app_container`
  and adds the entry `X.X.X.X app.local` to your hosts file.

### Multiple static domains

```ruby
Vagrant.configure("2") do |config|
  config.vm.box = "hashicorp/bionic64"

  # Explicit mappings (no Docker inspect)
  config.docker_hosts.domains = {
    "api.local"  => "172.28.10.10",
    "web.local"  => "172.28.10.11",
    "db.local"   => "172.28.10.12"
  }
end
```

---

## Vagrantfile configuration

All options:

| Key               | Type   | Default              | Notes |
|-------------------|--------|----------------------|-------|
| `domains`         | Hash   | `{}`                 | Map of `domain => ip`. When set, **no auto‑detect** is performed. |
| `domain`          | String | `nil`                | Single domain to map via **auto‑detect** (requires `container_name`). |
| `container_name`  | String | `"noesi-flowfind"`   | Docker container name used for auto‑detect. |

**Rules**

- If `domains` is **empty** and `domain` is **set**, the plugin will try to **inspect the container IP** and map it to `domain`.
- If `domains` has entries, they are used **as is**; `domain`/`container_name` are ignored.

---

## CLI usage

```
vagrant hosts <command>

Commands:
  add     # Add configured entries to the hosts file
  remove  # Remove configured entries from the hosts file
  view    # Print configured entries (from Vagrantfile)
```

Examples:

```bash
vagrant hosts view
vagrant hosts add
vagrant hosts remove
```

---

## How it works

- **During `vagrant up`**  
  The plugin reads `config.docker_hosts`. If only `domain` is provided, it runs `docker inspect` to get an IP. Then it **removes any previous lines** containing those domains from the hosts file and **appends** new lines (`<ip> <domain>`).

- **During `vagrant destroy`**  
  The plugin **removes** any hosts lines that contain your configured domain names.

> The update is **idempotent**: running `add` multiple times won’t duplicate entries for the same domain.

---

## Permissions & OS notes

- **Linux / macOS**: modifying `/etc/hosts` requires privileges. The plugin pipes through `sudo tee -a` when appending, and writes the file when removing. You may be prompted for your password.
- **Windows**: the plugin uses **PowerShell elevation** (`Start-Process -Verb RunAs`) when needed to append or rewrite the hosts file.

> If your shell is already elevated (root/Admin), no prompts appear.

---

## Troubleshooting

- **Container IP empty with auto‑detect**: Ensure the Docker container `container_name` is running and attached to a network with an IP (check `docker inspect` output).
- **Permission denied**: Run your terminal as Administrator (Windows) or ensure `sudo` is available (Linux/macOS).
- **Entry not removed**: The cleanup matches **by domain substring**. If your hosts line contains extra comments or formatting, make sure the domain string appears on the line.

---

## Contributing & Development

```bash
git clone https://github.com/julienpoirou/vagrant-docker-hosts-manager
cd vagrant-docker-hosts-manager
bundle install
rake          # runs RSpec
```

- Conventional Commits enforced in PRs.
- CI runs RuboCop, tests, and builds the gem.
- See `docs/en/CONTRIBUTING.md` and `docs/en/DEVELOPMENT.md` if present.

---

## License

MIT © 2025 [Julien Poirou](mailto:julienpoirou@protonmail.com)
