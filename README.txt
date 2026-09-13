# Fedora Auto Update Installer

Petit installateur pour automatiser les mises à jour sur **Fedora KDE Plasma**.

Il met automatiquement à jour :

- Fedora et les paquets RPM ;
- le kernel ;
- KDE Plasma ;
- les applications Flatpak système ;
- les firmwares compatibles avec `fwupd`.

Des notifications KDE indiquent également quand une mise à jour démarre, se termine ou rencontre une erreur.

---

## Installation

### 1. Télécharger le projet

```bash
git clone https://github.com/jeroval/fedora-auto-update-installer.git
```

Puis entrer dans le dossier :

```bash
cd fedora-auto-update-installer
```

### 2. Rendre l'installateur exécutable

```bash
chmod +x install.sh
```

### 3. Installer

```bash
sudo ./install.sh
```

L'installateur vérifie automatiquement les prérequis et installe les dépendances manquantes.

À la fin, une notification KDE doit apparaître pour confirmer que le système fonctionne.

---

## Fonctionnement

Après installation, les mises à jour sont lancées automatiquement :

- quelques minutes après le démarrage du PC ;
- puis environ une fois toutes les 24 heures.

Le système vérifie successivement :

```text
Fedora / RPM
     ↓
Flatpak
     ↓
Firmware
     ↓
Notification KDE
```

Aucun redémarrage automatique n'est effectué.

---

## Lancer une mise à jour manuellement

Pour lancer immédiatement une vérification complète :

```bash
sudo systemctl start fedora-auto-update.service
```

---

## Suivre la mise à jour

Pour voir ce que fait le script en direct :

```bash
journalctl -fu fedora-auto-update.service
```

Quitter avec :

```text
Ctrl+C
```

Cela n'arrête pas la mise à jour.

---

## Voir le résultat

État de la dernière exécution :

```bash
cat /run/fedora-auto-update/status
```

Détails :

```bash
cat /run/fedora-auto-update/details
```

Exemple :

```text
Mise à jour terminée

DNF / RPM      ✓  12 paquet(s)
Flatpak        ✓  2 mise(s) à jour
Firmware       ✓

Total : 14 mises à jour
Durée : 1 min 34 s
```

---

## Vérifier que l'automatisation est active

Timer des mises à jour :

```bash
systemctl status fedora-auto-update.timer
```

Timer des notifications KDE :

```bash
systemctl --user status fedora-update-notifier.timer
```

Ils doivent afficher :

```text
Active: active (waiting)
```

---

## Notifications

Le système peut afficher des notifications pour :

- la mise à jour Fedora / RPM ;
- les applications Flatpak ;
- les firmwares ;
- la fin de la mise à jour ;
- les erreurs éventuelles.

La notification finale indique également combien de paquets ont été mis à jour.

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

`install.sh` installe automatiquement les fichiers présents dans le dossier `files/`.

---

## Détails techniques

Le système utilise :

- `dnf` pour Fedora et les paquets RPM ;
- `flatpak` pour les applications Flatpak système ;
- `fwupdmgr` pour les firmwares ;
- `systemd` pour la planification ;
- `notify-send` pour les notifications KDE.

Le script principal est installé ici :

```text
/usr/local/sbin/fedora-auto-update
```

Les services systemd sont installés ici :

```text
/etc/systemd/system/
```

Le système de notification utilisateur est installé ici :

```text
~/.local/bin/
~/.config/systemd/user/
```

---

## En cas de problème

Voir les logs :

```bash
journalctl -u fedora-auto-update.service
```

Voir uniquement les logs du démarrage actuel :

```bash
journalctl -b -u fedora-auto-update.service
```

Relancer manuellement une mise à jour :

```bash
sudo systemctl start fedora-auto-update.service
```

---

## Compatibilité

Projet conçu pour :

- Fedora Linux ;
- KDE Plasma ;
- systemd ;
- DNF5 ;
- Flatpak ;
- fwupd.