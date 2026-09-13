# Fedora Auto Update Installer

Automatise les mises à jour sur **Fedora KDE Plasma**.

Le programme met automatiquement à jour :

- Fedora et les paquets RPM
- Le kernel Linux
- KDE Plasma
- Les applications Flatpak
- Les firmwares compatibles avec `fwupd`

Des notifications KDE indiquent la progression et le résultat des mises à jour.

> **Aucun redémarrage automatique n'est effectué.**

## Installation

### 1. Télécharger le projet

```bash
git clone https://github.com/jeroval/fedora-auto-update-installer.git
cd fedora-auto-update-installer
```

### 2. Lancer l'installation

```bash
chmod +x install.sh
sudo ./install.sh
```

C'est tout.

Le programme vérifie automatiquement les prérequis, installe les dépendances manquantes et configure les services nécessaires.

Une notification KDE apparaît à la fin pour confirmer que l'installation fonctionne.

## Fonctionnement

Une vérification des mises à jour est lancée :

- Quelques minutes après le démarrage du PC
- Puis environ toutes les 24 heures

Les mises à jour sont effectuées dans cet ordre :

1. **Fedora / RPM**
2. **Flatpak**
3. **Firmware**
4. **Notification KDE**

## Lancer une mise à jour manuellement

```bash
sudo systemctl start fedora-auto-update.service
```

## Suivre une mise à jour

Pour afficher les opérations en cours :

```bash
journalctl -fu fedora-auto-update.service
```

Utiliser `Ctrl+C` pour quitter les logs.

Cela **n'arrête pas** la mise à jour.

## Voir le résultat

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

## Vérifier les mises à jour automatiques

```bash
systemctl status fedora-auto-update.timer
```

Le timer doit être indiqué comme actif :

```text
Active: active (waiting)
```

Pour vérifier les notifications :

```bash
systemctl --user status fedora-update-notifier.timer
```

## En cas de problème

Afficher les logs :

```bash
journalctl -u fedora-auto-update.service
```

Afficher uniquement les logs depuis le dernier démarrage :

```bash
journalctl -b -u fedora-auto-update.service
```

Relancer manuellement une mise à jour :

```bash
sudo systemctl start fedora-auto-update.service
```

## Compatibilité

- Fedora Linux
- KDE Plasma
- systemd
- DNF5
- Flatpak
- fwupd