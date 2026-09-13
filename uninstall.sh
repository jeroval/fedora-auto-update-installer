#!/bin/bash
# Retire uniquement l'outil pour le système et l'utilisateur ayant lancé sudo.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
trap 'printf "[ERREUR] Désinstallation interrompue à la ligne %s.\n" "$LINENO" >&2' ERR

if [ "${1:-}" = --help ]; then
    printf 'Usage : sudo ./uninstall.sh\nConserve les résultats, logs, caches, overrides systemd et dépendances.\n'
    exit 0
fi
if [ "$#" -ne 0 ]; then
    echo "Argument inconnu. Usage : sudo ./uninstall.sh" >&2
    exit 1
fi
if [ "$EUID" -ne 0 ]; then
    echo "Lance ce script depuis ta session avec sudo ./uninstall.sh" >&2
    exit 1
fi
INSTALL_USER="${SUDO_USER:-}"
if [ -z "$INSTALL_USER" ] || [ "$INSTALL_USER" = root ]; then
    echo "Utilisateur introuvable : lance sudo ./uninstall.sh depuis ta session." >&2
    exit 1
fi
USER_UID="$(id -u "$INSTALL_USER")"
USER_HOME="$(getent passwd "$INSTALL_USER" | cut -d: -f6)"
[[ "$USER_HOME" = /* && "$USER_HOME" != / && -d "$USER_HOME" ]] || exit 1
USER_SYSTEMD_DIR="$USER_HOME/.config/systemd/user"
USER_RUNTIME="/run/user/$USER_UID"
USER_BUS="$USER_RUNTIME/bus"

run_as_user() {
    sudo -u "$INSTALL_USER" env HOME="$USER_HOME" \
        XDG_CONFIG_HOME="$USER_HOME/.config" XDG_RUNTIME_DIR="$USER_RUNTIME" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$USER_BUS" "$@"
}

STATE_DIR="/var/lib/fedora-auto-update"
[ ! -L "$STATE_DIR" ] || { echo "Dossier d'état symbolique refusé" >&2; exit 1; }
install -d -o root -g root -m 0755 "$STATE_DIR"
for name in install.lock update.lock; do
    [ ! -L "$STATE_DIR/$name" ] || { echo "Verrou symbolique refusé" >&2; exit 1; }
done

echo "[INFO] Attente de la fin des installations et mises à jour en cours…"
# Même ordre que l'installateur : ne jamais tuer une transaction de paquets.
exec 8>"$STATE_DIR/install.lock"
flock -x 8
exec 9>"$STATE_DIR/update.lock"
flock -x 9

echo "[INFO] Désactivation de la planification système"
if [ "$(systemctl show fedora-auto-update.timer -p LoadState --value)" != not-found ]; then
    systemctl disable --now fedora-auto-update.timer
fi
# Les verrous garantissent qu'aucune transaction de notre script n'est active.
# Arrêter aussi un éventuel démarrage en attente ou une reprise programmée.
if [ "$(systemctl show fedora-auto-update.service -p LoadState --value)" != not-found ]; then
    systemctl stop fedora-auto-update.service
fi

echo "[INFO] Désactivation des notifications pour $INSTALL_USER"
if [ -S "$USER_BUS" ]; then
    if [ "$(run_as_user systemctl --user show fedora-update-notifier.timer -p LoadState --value)" != not-found ]; then
        run_as_user systemctl --user disable --now fedora-update-notifier.timer
    fi
    if [ "$(run_as_user systemctl --user show fedora-update-notifier.service -p LoadState --value)" != not-found ]; then
        run_as_user systemctl --user stop fedora-update-notifier.service
    fi
elif [ -f "$USER_SYSTEMD_DIR/fedora-update-notifier.timer" ]; then
    run_as_user systemctl --user --no-reload disable fedora-update-notifier.timer
fi

# Les suppressions dans le home sont réalisées sans privilèges root.
run_as_user rm -f -- \
    "$USER_HOME/.local/bin/fedora-update-notifier" \
    "$USER_SYSTEMD_DIR/fedora-update-notifier.service" \
    "$USER_SYSTEMD_DIR/fedora-update-notifier.timer" \
    "$USER_SYSTEMD_DIR/timers.target.wants/fedora-update-notifier.timer"
rm -f -- \
    /usr/local/sbin/fedora-auto-update \
    /etc/systemd/system/fedora-auto-update.service \
    /etc/systemd/system/fedora-auto-update.timer \
    /etc/systemd/system/timers.target.wants/fedora-auto-update.timer

systemctl daemon-reload
if [ -S "$USER_BUS" ]; then
    run_as_user systemctl --user daemon-reload
fi

for path in /usr/local/sbin/fedora-auto-update \
    /etc/systemd/system/fedora-auto-update.service \
    /etc/systemd/system/fedora-auto-update.timer \
    "$USER_HOME/.local/bin/fedora-update-notifier" \
    "$USER_SYSTEMD_DIR/fedora-update-notifier.service" \
    "$USER_SYSTEMD_DIR/fedora-update-notifier.timer"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
        printf '[ERREUR] Fichier encore présent : %s\n' "$path" >&2
        exit 1
    fi
done
echo "[OK] Outil désinstallé pour le système et $INSTALL_USER."
echo "[INFO] Résultats et logs conservés dans $STATE_DIR."
echo "[INFO] Dépendances, cache utilisateur, overrides systemd et dépôt Git conservés."
echo "[INFO] Les éventuelles notifications configurées pour d'autres utilisateurs ne sont pas supprimées."
