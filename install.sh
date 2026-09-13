#!/bin/bash

set -u

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="$BASE_DIR/files"

SYSTEM_SCRIPT_SRC="$FILES_DIR/fedora-auto-update"
SYSTEM_SERVICE_SRC="$FILES_DIR/fedora-auto-update.service"
SYSTEM_TIMER_SRC="$FILES_DIR/fedora-auto-update.timer"

USER_NOTIFIER_SRC="$FILES_DIR/fedora-update-notifier"
USER_SERVICE_SRC="$FILES_DIR/fedora-update-notifier.service"
USER_TIMER_SRC="$FILES_DIR/fedora-update-notifier.timer"

SYSTEM_SCRIPT_DST="/usr/local/sbin/fedora-auto-update"
SYSTEM_SERVICE_DST="/etc/systemd/system/fedora-auto-update.service"
SYSTEM_TIMER_DST="/etc/systemd/system/fedora-auto-update.timer"

STATE_DIR="/run/fedora-auto-update"

GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
RESET="\033[0m"

ok()   { echo -e "${GREEN}[OK]${RESET} $1"; }
info() { echo -e "${BLUE}[INFO]${RESET} $1"; }
warn() { echo -e "${YELLOW}[ATTENTION]${RESET} $1"; }
fail() { echo -e "${RED}[ERREUR]${RESET} $1"; }

die() {
    fail "$1"
    exit 1
}

if [ "$EUID" -ne 0 ]; then
    die "Lance ce script avec sudo : sudo ./install.sh"
fi

INSTALL_USER="${SUDO_USER:-}"

if [ -z "$INSTALL_USER" ] || [ "$INSTALL_USER" = "root" ]; then
    die "Impossible d'identifier l'utilisateur graphique. Lance le script depuis ta session avec sudo ./install.sh"
fi

id "$INSTALL_USER" >/dev/null 2>&1 ||
    die "Utilisateur introuvable : $INSTALL_USER"

USER_UID="$(id -u "$INSTALL_USER")"
USER_GID="$(id -g "$INSTALL_USER")"
USER_HOME="$(getent passwd "$INSTALL_USER" | cut -d: -f6)"

USER_BIN_DIR="$USER_HOME/.local/bin"
USER_SYSTEMD_DIR="$USER_HOME/.config/systemd/user"

USER_NOTIFIER_DST="$USER_BIN_DIR/fedora-update-notifier"
USER_SERVICE_DST="$USER_SYSTEMD_DIR/fedora-update-notifier.service"
USER_TIMER_DST="$USER_SYSTEMD_DIR/fedora-update-notifier.timer"

echo
echo "============================================================"
echo " Fedora Automatic Update - Installation"
echo "============================================================"
echo

info "Utilisateur : $INSTALL_USER"
info "Home        : $USER_HOME"
info "Sources     : $FILES_DIR"

[ -f /etc/fedora-release ] ||
    die "Ce système ne semble pas être Fedora."

ok "$(cat /etc/fedora-release)"

# Vérifier que tous les fichiers source existent
REQUIRED_FILES=(
    "$SYSTEM_SCRIPT_SRC"
    "$SYSTEM_SERVICE_SRC"
    "$SYSTEM_TIMER_SRC"
    "$USER_NOTIFIER_SRC"
    "$USER_SERVICE_SRC"
    "$USER_TIMER_SRC"
)

for file in "${REQUIRED_FILES[@]}"; do
    [ -f "$file" ] || die "Fichier d'installation absent : $file"
done

ok "Tous les fichiers source sont présents"

# Dépendances
REQUIRED_PACKAGES=(
    dnf5
    flatpak
    fwupd
    libnotify
    python3
)

MISSING_PACKAGES=()

for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! rpm -q "$pkg" >/dev/null 2>&1; then
        MISSING_PACKAGES+=("$pkg")
    fi
done

if [ "${#MISSING_PACKAGES[@]}" -gt 0 ]; then
    warn "Dépendances manquantes : ${MISSING_PACKAGES[*]}"
    info "Installation..."
    dnf install -y "${MISSING_PACKAGES[@]}" ||
        die "Échec de l'installation des dépendances."
else
    ok "Toutes les dépendances RPM sont installées"
fi

REQUIRED_COMMANDS=(
    dnf
    flatpak
    fwupdmgr
    notify-send
    python3
    busctl
    systemctl
)

for cmd in "${REQUIRED_COMMANDS[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 ||
        die "Commande requise introuvable : $cmd"
done

ok "Toutes les commandes requises sont disponibles"

# Validation syntaxique avant copie
bash -n "$SYSTEM_SCRIPT_SRC" ||
    die "Erreur de syntaxe dans fedora-auto-update"

bash -n "$USER_NOTIFIER_SRC" ||
    die "Erreur de syntaxe dans fedora-update-notifier"

ok "Syntaxe Bash valide"

# Installation système
info "Installation des fichiers système"

install -o root -g root -m 0755 \
    "$SYSTEM_SCRIPT_SRC" \
    "$SYSTEM_SCRIPT_DST"

install -o root -g root -m 0644 \
    "$SYSTEM_SERVICE_SRC" \
    "$SYSTEM_SERVICE_DST"

install -o root -g root -m 0644 \
    "$SYSTEM_TIMER_SRC" \
    "$SYSTEM_TIMER_DST"

ok "Fichiers système installés"

# Installation utilisateur
info "Installation des fichiers utilisateur"

install -d -o "$USER_UID" -g "$USER_GID" -m 0755 \
    "$USER_BIN_DIR"

install -d -o "$USER_UID" -g "$USER_GID" -m 0755 \
    "$USER_SYSTEMD_DIR"

install -o "$USER_UID" -g "$USER_GID" -m 0755 \
    "$USER_NOTIFIER_SRC" \
    "$USER_NOTIFIER_DST"

install -o "$USER_UID" -g "$USER_GID" -m 0644 \
    "$USER_SERVICE_SRC" \
    "$USER_SERVICE_DST"

install -o "$USER_UID" -g "$USER_GID" -m 0644 \
    "$USER_TIMER_SRC" \
    "$USER_TIMER_DST"

ok "Fichiers utilisateur installés"

# Validation systemd
systemd-analyze verify \
    "$SYSTEM_SERVICE_DST" \
    "$SYSTEM_TIMER_DST" >/dev/null ||
    die "Validation des unités systemd système échouée."

ok "Unités systemd système valides"

# Recharger et activer le timer système
systemctl daemon-reload ||
    die "Échec de systemctl daemon-reload"

systemctl enable --now fedora-auto-update.timer ||
    die "Impossible d'activer fedora-auto-update.timer"

systemctl is-enabled fedora-auto-update.timer >/dev/null 2>&1 ||
    die "fedora-auto-update.timer n'est pas activé"

systemctl is-active fedora-auto-update.timer >/dev/null 2>&1 ||
    die "fedora-auto-update.timer n'est pas actif"

ok "Timer système actif et activé au démarrage"

# Vérifier qu'une session utilisateur systemd est disponible
USER_RUNTIME="/run/user/$USER_UID"
USER_BUS="$USER_RUNTIME/bus"

if [ ! -S "$USER_BUS" ]; then
    warn "Bus D-Bus utilisateur indisponible."
    warn "Les fichiers sont installés, mais le timer de notification ne peut pas être activé maintenant."
    USER_SYSTEMD_OK=0
else
    USER_SYSTEMD_OK=1

    run_user_systemctl() {
        sudo -u "$INSTALL_USER" \
            XDG_RUNTIME_DIR="$USER_RUNTIME" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$USER_BUS" \
            systemctl --user "$@"
    }

    run_user_systemctl daemon-reload ||
        die "Échec du daemon-reload systemd utilisateur"

    run_user_systemctl enable --now fedora-update-notifier.timer ||
        die "Impossible d'activer le timer utilisateur"

    run_user_systemctl is-enabled fedora-update-notifier.timer >/dev/null 2>&1 ||
        die "Le timer utilisateur n'est pas activé"

    run_user_systemctl is-active fedora-update-notifier.timer >/dev/null 2>&1 ||
        die "Le timer utilisateur n'est pas actif"

    ok "Timer de notification actif"
fi

# Vérification permissions
info "Vérification des permissions"

[ "$(stat -c '%U:%G:%a' "$SYSTEM_SCRIPT_DST")" = "root:root:755" ] ||
    die "Permissions incorrectes sur $SYSTEM_SCRIPT_DST"

[ "$(stat -c '%U:%G:%a' "$SYSTEM_SERVICE_DST")" = "root:root:644" ] ||
    die "Permissions incorrectes sur $SYSTEM_SERVICE_DST"

[ "$(stat -c '%U:%G:%a' "$SYSTEM_TIMER_DST")" = "root:root:644" ] ||
    die "Permissions incorrectes sur $SYSTEM_TIMER_DST"

[ "$(stat -c '%U' "$USER_NOTIFIER_DST")" = "$INSTALL_USER" ] ||
    die "Propriétaire incorrect sur $USER_NOTIFIER_DST"

ok "Permissions principales correctes"

# Test fonctionnel de notification
if [ "$USER_SYSTEMD_OK" -eq 1 ]; then
    info "Test de fin d'installation : notification KDE"

    mkdir -p "$STATE_DIR"
    chmod 755 "$STATE_DIR"

    TEST_RUN_ID="INSTALL-TEST-$(date +%s)-$$"

    echo "$TEST_RUN_ID" > "$STATE_DIR/run-id"
    echo "SUCCESS" > "$STATE_DIR/status"

    cat > "$STATE_DIR/details" <<EOF
Installation terminée

DNF / RPM      ✓
Flatpak        ✓
Firmware       ✓

Test automatique de notification.
EOF

    chmod 644 \
        "$STATE_DIR/run-id" \
        "$STATE_DIR/status" \
        "$STATE_DIR/details"

    sudo -u "$INSTALL_USER" \
        XDG_RUNTIME_DIR="$USER_RUNTIME" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$USER_BUS" \
        "$USER_NOTIFIER_DST"

    if [ $? -eq 0 ]; then
        ok "Test de notification exécuté"
    else
        warn "Le test de notification a échoué."
        warn "L'installation principale reste terminée."
    fi
fi

echo
echo "============================================================"
echo " INSTALLATION TERMINÉE"
echo "============================================================"
echo
echo "Mise à jour manuelle :"
echo "  sudo systemctl start fedora-auto-update.service"
echo
echo "Logs :"
echo "  journalctl -fu fedora-auto-update.service"
echo
echo "État :"
echo "  cat /run/fedora-auto-update/status"
echo "  cat /run/fedora-auto-update/details"
echo
echo "Timers :"
echo "  systemctl status fedora-auto-update.timer"
echo "  systemctl --user status fedora-update-notifier.timer"
echo
