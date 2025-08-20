# vagrant-docker-hosts-manager

[![CI](https://github.com/julienpoirou/vagrant-docker-hosts-manager/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/julienpoirou/vagrant-docker-hosts-manager/actions/workflows/ci.yml)
[![CodeQL](https://github.com/julienpoirou/vagrant-docker-hosts-manager/actions/workflows/codeql.yml/badge.svg)](https://github.com/julienpoirou/vagrant-docker-hosts-manager/actions/workflows/codeql.yml)
[![Release](https://img.shields.io/github/v/release/julienpoirou/vagrant-docker-hosts-manager?include_prereleases&sort=semver)](https://github.com/julienpoirou/vagrant-docker-hosts-manager/releases)
[![RubyGems](https://img.shields.io/gem/v/vagrant-docker-hosts-manager.svg)](https://rubygems.org/gems/vagrant-docker-hosts-manager)
[![License](https://img.shields.io/github/license/julienpoirou/vagrant-docker-hosts-manager.svg)](LICENSE.md)
[![Conventional Commits](https://img.shields.io/badge/Conventional%20Commits-1.0.0-%23FE5196.svg)](https://www.conventionalcommits.org)
[![Renovate](https://img.shields.io/badge/Renovate-enabled-brightgreen.svg)](https://renovatebot.com)

Plugin Vagrant pour **gérer des noms d’hôte personnalisés** en mettant à jour le fichier `hosts` local (Windows/Linux/macOS) pour des environnements basés sur Docker.

- Ajoute/supprime des entrées du hosts lors de `vagrant up` / `vagrant destroy`
- **Auto‑détection** de l’IP d’un conteneur Docker pour un domaine unique
- Mises à jour sûres et idempotentes : remplace les anciennes entrées pour les domaines configurés
- Fonctionne sur toutes les plateformes

> Exigences : **Vagrant ≥ 2.2**, **Ruby ≥ 3.1**, **Docker (CLI + daemon)** pour l’auto‑détection.

---

## Table des matières

- [Pourquoi ce plugin ?](#pourquoi-ce-plugin-)
- [Installation](#installation)
- [Démarrage rapide](#démarrage-rapide)
- [Configuration du Vagrantfile](#configuration-du-vagrantfile)
- [Utilisation en CLI](#utilisation-en-cli)
- [Fonctionnement](#fonctionnement)
- [Permissions & systèmes](#permissions--systèmes)
- [Dépannage](#dépannage)
- [Contribuer & Développement](#contribuer--développement)
- [Licence](#licence)

> 🇬🇧 **English:** see [README.md](README.md)

---

## Pourquoi ce plugin ?

Avec Docker + Vagrant, on a souvent besoin de **noms d’hôte conviviaux** (ex. `app.local`) qui résolvent vers l’IP d’un conteneur. Le faire à la main dans `/etc/hosts` ou `C:\Windows\System32\drivers\etc\hosts` est source d’erreurs et peu portable entre coéquipiers.

Ce plugin :
- **Écrit** les entrées nécessaires pendant `vagrant up`.
- **Nettoie** proprement lors de `vagrant destroy`.
- Peut **auto‑résoudre** l’IP d’un conteneur (`docker inspect`) si vous ne fournissez qu’un `domain` et un `container_name`.

---

## Installation

Depuis RubyGems (une fois publié) :

```bash
vagrant plugin install vagrant-docker-hosts-manager
```

Depuis les sources (chemin local) :

```bash
git clone https://github.com/julienpoirou/vagrant-docker-hosts-manager
cd vagrant-docker-hosts-manager
bundle install
rake
vagrant plugin install .    # installe depuis la gemspec locale
```

Vérifier la disponibilité :

```bash
vagrant hosts --help
```

---

## Démarrage rapide

### Vagrantfile minimal (auto‑détection d’un conteneur)

```ruby
Vagrant.configure("2") do |config|
  config.vm.box = "hashicorp/bionic64"

  # Auto‑détecte l’IP d’un conteneur Docker en cours d’exécution
  # et la mappe à un domaine unique (ex. http://app.local)
  config.docker_hosts.domain         = "app.local"
  config.docker_hosts.container_name = "my_app_container"   # docker ps --format '{{.Names}}'
end
```

- Au `vagrant up`, le plugin exécute
  `docker inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" my_app_container`
  et ajoute l’entrée `X.X.X.X app.local` dans votre fichier hosts.

### Plusieurs domaines statiques

```ruby
Vagrant.configure("2") do |config|
  config.vm.box = "hashicorp/bionic64"

  # Mappages explicites (sans docker inspect)
  config.docker_hosts.domains = {
    "api.local"  => "172.28.10.10",
    "web.local"  => "172.28.10.11",
    "db.local"   => "172.28.10.12"
  }
end
```

---

## Configuration du Vagrantfile

Toutes les options :

| Clé              | Type  | Par défaut           | Notes |
|------------------|-------|----------------------|-------|
| `domains`        | Hash  | `{}`                 | Table `domaine => ip`. Si renseignée, **pas d’auto‑détection**. |
| `domain`         | String| `nil`                | Domaine unique à mapper via **auto‑détection** (requiert `container_name`). |
| `container_name` | String| `"noesi-flowfind"` | Nom du conteneur Docker utilisé pour l’auto‑détection. |

**Règles**

- Si `domains` est **vide** et `domain` est **renseigné**, le plugin tentera **d’inspecter l’IP** du conteneur et de la mapper à `domain`.
- Si `domains` contient des entrées, elles sont utilisées **telles quelles** ; `domain`/`container_name` sont ignorés.

---

## Utilisation en CLI

```
vagrant hosts <commande>

Commandes :
  add     # Ajoute les entrées configurées au fichier hosts
  remove  # Supprime les entrées configurées du fichier hosts
  view    # Affiche les entrées configurées (depuis le Vagrantfile)
```

Exemples :

```bash
vagrant hosts view
vagrant hosts add
vagrant hosts remove
vagrant hosts version
```

---

## Fonctionnement

- **Pendant `vagrant up`**  
  Le plugin lit `config.docker_hosts`. Si seul `domain` est fourni, il exécute `docker inspect` pour récupérer une IP. Puis il **retire toute ligne précédente** contenant ces domaines dans le fichier hosts et **ajoute** les nouvelles lignes (`<ip> <domaine>`).

- **Pendant `vagrant destroy`**  
  Le plugin **supprime** toute ligne du hosts contenant vos domaines configurés.

> La mise à jour est **idempotente** : exécuter `add` plusieurs fois ne dupliquera pas les entrées pour un même domaine.

---

## Permissions & systèmes

- **Linux / macOS** : la modification de `/etc/hosts` requiert des privilèges. Le plugin passe par `sudo tee -a` pour l’ajout, et ré‑écrit le fichier lors de la suppression. Il se peut que votre mot de passe soit demandé.
- **Windows** : le plugin utilise **PowerShell en élévation** (`Start-Process -Verb RunAs`) lorsque nécessaire pour ajouter ou ré‑écrire le fichier hosts.

> Si votre terminal est déjà élevé (root/Admin), aucun prompt n’apparaîtra.

---

## Dépannage

- **IP de conteneur vide en auto‑détection** : vérifiez que le conteneur `container_name` est en cours d’exécution et rattaché à un réseau avec une IP (voir la sortie de `docker inspect`).  
- **Permission refusée** : lancez le terminal en Administrateur (Windows) ou assurez‑vous que `sudo` est disponible (Linux/macOS).  
- **Entrée non supprimée** : le nettoyage correspond **par sous‑chaîne de domaine**. Si votre ligne contient des commentaires/formattage supplémentaires, assurez‑vous que le domaine est bien présent tel quel sur la ligne.

---

## Contribuer & Développement

```bash
git clone https://github.com/julienpoirou/vagrant-docker-hosts-manager
cd vagrant-docker-hosts-manager
bundle install
rake          # exécute RSpec
```

- Conventional Commits exigés dans les PRs.
- La CI exécute RuboCop, les tests, et construit la gem.
- Voir `docs/fr/CONTRIBUTING.md` et `docs/fr/DEVELOPMENT.md` si présents.

---

## Licence

MIT © 2025 [Julien Poirou](mailto:julienpoirou@protonmail.com)
