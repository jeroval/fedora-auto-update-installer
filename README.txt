# Fedora Automatic Update Installer

Système d'automatisation des mises à jour pour **Fedora KDE Plasma**.

Il permet de gérer automatiquement :

- les mises à jour Fedora / RPM via **DNF** ;
- les mises à jour du **kernel** ;
- les mises à jour de **KDE Plasma** ;
- les applications **Flatpak système** ;
- les mises à jour **firmware** via `fwupd` ;
- l'exécution périodique via **systemd** ;
- les notifications dans **KDE Plasma** ;
- le comptage des paquets mis à jour ;
- les nouvelles tentatives automatiques en cas d'erreur.

Aucun redémarrage automatique n'est effectué.

---

## Architecture

```text
fedora-auto-update.timer
        │
        ▼
fedora-auto-update.service
        │
        ▼
/usr/local/sbin/fedora-auto-update
        │
        ├── DNF / RPM
        ├── Flatpak
        └── Firmware
        │
        ▼
/run/fedora-auto-update/
        ├── run-id
        ├── status
        └── details
        │
        ▼
fedora-update-notifier.timer
        │
        ▼
fedora-update-notifier.service
        │
        ▼
~/.local/bin/fedora-update-notifier
        │
        ▼
Notification KDE Plasma
```

---

## Structure du projet

```text
fedora-auto-update-installer/
├── install.sh
├── README.md
└── files/
    ├── fedora-auto-update
    ├── fedora-auto-update.service
    ├── fedora-auto-update.timer
    ├── fedora-update-notifier
    ├── fedora-update-notifier.service
    └── fedora-update-notifier.timer
```

Le script `install.sh` est volontairement séparé des fichiers installés.

Les fichiers présents dans `files/` sont copiés aux emplacements appropriés pendant l'installation.

---

# Installation

## 1. Extraire le projet

Extraire l'archive contenant le projet.

Puis ouvrir un terminal dans le dossier :

```bash
cd fedora-auto-update-installer
```

---

## 2. Rendre l'installateur exécutable

```bash
chmod +x install.sh
```

---

## 3. Lancer l'installation

```bash
sudo ./install.sh
```

Le script doit être lancé depuis la session graphique de l'utilisateur avec `sudo`.

Éviter de lancer directement :

```bash
sudo su
```

puis l'installateur, car celui-ci utilise `SUDO_USER` pour identifier l'utilisateur KDE auquel installer le système de notifications.

---

# Fonctionnement de l'installateur

Le script `install.sh` effectue automatiquement plusieurs contrôles avant et après l'installation.

## Vérification du système

L'installateur vérifie :

- que le système est Fedora ;
- que `systemd` est disponible ;
- que l'utilisateur ayant lancé `sudo` existe ;
- que sa session utilisateur peut être identifiée.

---

## Vérification des fichiers

Tous les fichiers nécessaires doivent être présents dans :

```text
files/
```

L'installation est interrompue si un fichier requis est absent.

---

## Vérification des dépendances

L'installateur vérifie notamment :

```text
dnf5
flatpak
fwupd
libnotify
python3
systemd
```

Il vérifie également la disponibilité des commandes :

```text
dnf
flatpak
fwupdmgr
notify-send
python3
busctl
systemctl
```

Les dépendances RPM manquantes sont installées automatiquement avec DNF.

---

## Vérification des scripts

Avant l'installation, la syntaxe Bash des scripts est contrôlée.

Par exemple :

```bash
bash -n files/fedora-auto-update
```

et :

```bash
bash -n files/fedora-update-notifier
```

Une erreur de syntaxe interrompt l'installation.

---

# Fichiers installés

## Script principal

Le fichier :

```text
files/fedora-auto-update
```

est installé dans :

```text
/usr/local/sbin/fedora-auto-update
```

Permissions :

```text
root:root
755
```

---

## Service de mise à jour

Le fichier :

```text
files/fedora-auto-update.service
```

est installé dans :

```text
/etc/systemd/system/fedora-auto-update.service
```

Permissions :

```text
root:root
644
```

---

## Timer de mise à jour

Le fichier :

```text
files/fedora-auto-update.timer
```

est installé dans :

```text
/etc/systemd/system/fedora-auto-update.timer
```

Permissions :

```text
root:root
644
```

---

## Script de notification

Le fichier :

```text
files/fedora-update-notifier
```

est installé dans :

```text
~/.local/bin/fedora-update-notifier
```

Le fichier appartient à l'utilisateur graphique.

---

## Service de notification

Le fichier :

```text
files/fedora-update-notifier.service
```

est installé dans :

```text
~/.config/systemd/user/fedora-update-notifier.service
```

---

## Timer de notification

Le fichier :

```text
files/fedora-update-notifier.timer
```

est installé dans :

```text
~/.config/systemd/user/fedora-update-notifier.timer
```

---

# Mises à jour DNF / RPM

Le script exécute :

```bash
dnf upgrade --refresh -y
```

Cela couvre notamment :

- Fedora ;
- kernel Linux ;
- KDE Plasma ;
- bibliothèques système ;
- applications RPM ;
- paquets provenant des dépôts RPM activés.

Le script utilise également l'historique DNF afin de déterminer le nombre de paquets affectés par la transaction.

La notification finale peut ainsi indiquer :

```text
DNF / RPM      ✓  12 paquet(s)
  • mis à jour : 11
  • installés  : 1
  • supprimés  : 0
```

---

# Mises à jour Flatpak

Les mises à jour disponibles sont détectées avec :

```bash
flatpak remote-ls --system --updates
```

Puis installées avec :

```bash
flatpak update --system -y --noninteractive
```

Cette configuration concerne les **Flatpaks installés au niveau système**.

Elle permet par exemple de mettre automatiquement à jour Google Chrome lorsqu'il est installé comme Flatpak système.

---

# Mises à jour firmware

Les métadonnées firmware sont actualisées avec :

```bash
fwupdmgr refresh --force
```

Puis les mises à jour sont installées avec :

```bash
fwupdmgr update -y
```

La disponibilité réelle des mises à jour dépend du matériel et de sa prise en charge par `fwupd` / LVFS.

---

# Planification automatique

Le timer système est :

```text
fedora-auto-update.timer
```

Sa configuration utilise :

```ini
OnBootSec=5min
OnUnitActiveSec=24h
Persistent=true
RandomizedDelaySec=5min
```

Une première exécution est donc programmée quelques minutes après le démarrage.

Les exécutions suivantes ont lieu approximativement toutes les 24 heures.

Le délai aléatoire évite que l'opération démarre systématiquement exactement au même instant.

---

# Gestion des erreurs

Le service principal utilise :

```ini
Restart=on-failure
RestartSec=2min
```

En cas d'échec, systemd peut donc effectuer une nouvelle tentative après deux minutes.

Des limites sont également configurées afin d'éviter une boucle de redémarrage permanente.

---

# États de la mise à jour

Pendant son fonctionnement, le script crée :

```text
/run/fedora-auto-update/
```

Ce répertoire contient :

```text
run-id
status
details
```

---

## `run-id`

Contient un identifiant unique pour chaque exécution.

Exemple :

```text
1757774218-5281
```

Cet identifiant permet notamment au système de notifications de distinguer deux mises à jour différentes.

---

## `status`

Contient l'état actuel.

Les principales valeurs sont :

```text
RUNNING_DNF
RUNNING_FLATPAK
RUNNING_FIRMWARE
SUCCESS
ERROR
```

---

## `details`

Contient les informations destinées notamment aux notifications KDE.

Exemple :

```text
Mise à jour terminée

DNF / RPM      ✓  12 paquet(s)
  • mis à jour : 11
  • installés  : 1
  • supprimés  : 0

Flatpak        ✓  2 mise(s) à jour
Firmware       ✓

Total : 14 mise(s) à jour

Durée : 1 min 34 s
13/09/2026 17:20:00
```

Le répertoire `/run` étant temporaire, ces informations sont recréées après chaque démarrage lors de la première exécution.

---

# Notifications KDE Plasma

Le système de notification fonctionne dans la session utilisateur KDE.

Le notifier surveille les changements d'état et affiche des notifications pour les différentes étapes.

## Étape 1

```text
Mise à jour Fedora — Étape 1/3

DNF / RPM
```

---

## Étape 2

```text
Mise à jour Fedora — Étape 2/3

Flatpak
```

---

## Étape 3

```text
Mise à jour Fedora — Étape 3/3

Firmware
```

---

## Succès

Exemple :

```text
Mise à jour Fedora terminée ✓

DNF / RPM      ✓  12 paquet(s)
  • mis à jour : 11
  • installés  : 1
  • supprimés  : 0

Flatpak        ✓  2 mise(s) à jour
Firmware       ✓

Total : 14 mise(s) à jour

Durée : 1 min 34 s
```

---

## Erreur

En cas d'échec, une notification critique est affichée :

```text
Erreur pendant la mise à jour Fedora
```

Les logs systemd permettent ensuite d'obtenir les détails.

---

# Gestion des notifications en double

Chaque exécution possède un identifiant unique :

```text
RUN_ID
```

Le notifier construit un identifiant d'événement à partir de :

```text
RUN_ID:STATUS
```

Exemple :

```text
1757774218-5281:SUCCESS
```

Le dernier événement affiché est conservé dans :

```text
~/.cache/fedora-auto-update/last-event
```

Cela évite d'afficher plusieurs fois la même notification.

Lors de la mise à jour suivante, un nouveau `RUN_ID` est automatiquement généré.

Il n'est donc pas nécessaire de supprimer manuellement le cache.

---

# Test de fin d'installation

À la fin de l'installation, `install.sh` crée un événement de test.

Exemple :

```text
Installation terminée

DNF / RPM      ✓
Flatpak        ✓
Firmware       ✓

Test automatique de notification.
```

Une notification KDE doit apparaître.

Ce test vérifie notamment :

- l'installation du notifier ;
- les permissions ;
- l'accès au bus D-Bus utilisateur ;
- le serveur de notifications KDE ;
- l'exécution du script de notification.

Le test **ne lance pas de véritable mise à jour du système**.

---

# Lancer manuellement une mise à jour

Pour lancer immédiatement toute la chaîne :

```bash
sudo systemctl start fedora-auto-update.service
```

Cela exécute successivement :

```text
DNF / RPM
    ↓
Flatpak
    ↓
Firmware
    ↓
Résultat
    ↓
Notification KDE
```

---

# Suivre la mise à jour en direct

Utiliser :

```bash
journalctl -fu fedora-auto-update.service
```

Pour quitter :

```text
Ctrl+C
```

Cela ferme uniquement l'affichage des logs.

La mise à jour continue en arrière-plan.

---

# Consulter l'état actuel

## État

```bash
cat /run/fedora-auto-update/status
```

---

## Détails

```bash
cat /run/fedora-auto-update/details
```

---

## Identifiant de l'exécution

```bash
cat /run/fedora-auto-update/run-id
```

---

# Vérifier les services

## Timer système

```bash
systemctl status fedora-auto-update.timer
```

L'état attendu est :

```text
Active: active (waiting)
```

---

## Timer de notification

```bash
systemctl --user status fedora-update-notifier.timer
```

L'état attendu est :

```text
Active: active (waiting)
```

---

# Afficher la prochaine exécution

```bash
systemctl list-timers fedora-auto-update.timer
```

La colonne `NEXT` indique la prochaine exécution prévue.

---

# Vérifier le service principal

```bash
systemctl status fedora-auto-update.service
```

Le service est de type `oneshot`.

Il est donc normal qu'il soit :

```text
inactive (dead)
```

lorsqu'aucune mise à jour n'est actuellement en cours.

---

# Consulter l'historique

Logs du service principal :

```bash
journalctl -u fedora-auto-update.service
```

Logs du démarrage actuel :

```bash
journalctl -b -u fedora-auto-update.service
```

Logs en temps réel :

```bash
journalctl -fu fedora-auto-update.service
```

---

# Tester avec une véritable mise à jour DNF

Si le système est déjà entièrement à jour, il est possible de rétrograder temporairement un petit paquet non critique pour tester la chaîne.

Par exemple, afficher les versions disponibles de `nano` :

```bash
dnf repoquery --showduplicates nano
```

Si une ancienne version est disponible :

```bash
sudo dnf downgrade nano
```

Vérifier attentivement la transaction proposée par DNF avant de confirmer.

Si DNF souhaite modifier de nombreuses dépendances, annuler l'opération.

Vérifier ensuite la version installée :

```bash
rpm -q nano
```

Puis lancer le système de mise à jour :

```bash
sudo systemctl start fedora-auto-update.service
```

Le paquet doit être remis à jour automatiquement.

La notification finale devrait alors comptabiliser la transaction.

Exemple :

```text
DNF / RPM      ✓  1 paquet(s)
  • mis à jour : 1
  • installés  : 0
  • supprimés  : 0

Flatpak        ✓  0 mise à jour
Firmware       ✓

Total : 1 mise à jour
```

---

# Redémarrage

Aucun redémarrage automatique n'est effectué.

Même après :

- une mise à jour du kernel ;
- une mise à jour importante de KDE ;
- une mise à jour de bibliothèques système ;
- certaines mises à jour firmware ;

la décision de redémarrer reste manuelle.

Pour redémarrer :

```bash
systemctl reboot
```

---

# Commandes utiles

## Lancer une mise à jour

```bash
sudo systemctl start fedora-auto-update.service
```

## Suivre les logs

```bash
journalctl -fu fedora-auto-update.service
```

## Vérifier le timer

```bash
systemctl status fedora-auto-update.timer
```

## Voir la prochaine exécution

```bash
systemctl list-timers fedora-auto-update.timer
```

## Vérifier les notifications

```bash
systemctl --user status fedora-update-notifier.timer
```

## Voir le résultat

```bash
cat /run/fedora-auto-update/details
```

## Voir l'état

```bash
cat /run/fedora-auto-update/status
```

## Voir le RUN ID

```bash
cat /run/fedora-auto-update/run-id
```

---

# Résumé

Une fois installé, le système fonctionne automatiquement :

```text
Démarrage de Fedora
        ↓
Attente de quelques minutes
        ↓
DNF / RPM
        ↓
Flatpak système
        ↓
Firmware
        ↓
Comptage des mises à jour
        ↓
Écriture du résultat
        ↓
Notification KDE Plasma
        ↓
Nouvelle vérification ~24 h plus tard
```

Aucune intervention manuelle n'est nécessaire pour le fonctionnement normal des mises à jour.