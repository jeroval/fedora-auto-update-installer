# Fedora Auto Update Installer

Automatise les mises à jour sur **Fedora KDE Plasma**.

Le système met à jour automatiquement :

- Fedora et les paquets RPM
- le kernel
- KDE Plasma
- les applications Flatpak système
- les firmwares compatibles avec `fwupd`

Des notifications KDE indiquent le début, la progression et la fin des mises à jour.

## Installation

Télécharger le projet :

```bash
git clone https://github.com/jeroval/fedora-auto-update-installer.git
```

Entrer dans le dossier :

```bash
cd fedora-auto-update-installer
```

Rendre l'installateur exécutable :

```bash
chmod +x install.sh
```

Lancer l'installation :

```bash
sudo ./install.sh
```

L'installateur vérifie les prérequis, installe les dépendances manquantes et configure automatiquement les services.

Une notification KDE est envoyée à la fin pour vérifier que le système fonctionne.

## Fonctionnement

Après installation, les mises à jour sont lancées automatiquement :

- quelques minutes après le démarrage du PC
- puis environ une fois toutes les 24 heures

Ordre des mises à jour :

1. Fedora / RPM
2. Flatpak
3. Firmware
4. Notification KDE

Aucun redémarrage automatique n'est effectué.

## Lancer une mise à jour manuellement

```bash
sudo systemctl start fedora-auto-update.service
```

## Voir les logs

```bash
journalctl -fu fedora-auto-update.service
```

Utiliser `Ctrl+C` pour quitter l'affichage des logs.

Cela n'arrête pas la mise à jour.

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

## Vérifier que l'automatisation est active

Mises à jour :

```bash
systemctl status fedora-auto-update.timer
```

Notifications KDE :

```bash
systemctl --user status fedora-update-notifier.timer
```

Dans les deux cas, l'état attendu est :

```text
Active: active (waiting)
```

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

## En cas de problème

Afficher les logs :

```bash
journalctl -u fedora-auto-update.service
```

Afficher uniquement les logs du démarrage actuel :

```bash
journalctl -b -u fedora-auto-update.service
```

Relancer une mise à jour :

```bash
sudo systemctl start fedora-auto-update.service
```

## Compatibilité

Prévu pour :

- Fedora Linux
- KDE Plasma
- systemd
- DNF5
- Flatpak
- fwupd
