#!/bin/bash

set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
trap 'printf "[ERREUR] Installation interrompue à la ligne %s.\n" "$LINENO" >&2' ERR

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

[[ "$USER_HOME" = /* && -d "$USER_HOME" ]] || die "Dossier personnel invalide : $USER_HOME"

USER_BIN_DIR="$USER_HOME/.local/bin"
USER_SYSTEMD_DIR="$USER_HOME/.config/systemd/user"

USER_NOTIFIER_DST="$USER_BIN_DIR/fedora-update-notifier"
USER_SERVICE_DST="$USER_SYSTEMD_DIR/fedora-update-notifier.service"
USER_TIMER_DST="$USER_SYSTEMD_DIR/fedora-update-notifier.timer"

# sudo ne conserve pas nécessairement le contexte de la session graphique.
USER_RUNTIME="/run/user/$USER_UID"
USER_BUS="$USER_RUNTIME/bus"

run_as_user() {
    sudo -u "$INSTALL_USER" env \
        HOME="$USER_HOME" \
        XDG_CONFIG_HOME="$USER_HOME/.config" \
        XDG_RUNTIME_DIR="$USER_RUNTIME" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$USER_BUS" \
        "$@"
}

run_user_systemctl() {
    run_as_user systemctl --user "$@"
}

# Refuser de valider un ancien succès ou une exécution encore en cours.
# Affiche l'identifiant de l'événement final à retrouver dans le cache utilisateur.
verify_update_receipt() {
    python3 - "$1" "$2" <<'PYTHON'
import json, pathlib, sys
root, previous_id = pathlib.Path(sys.argv[1]), sys.argv[2]
try:
    current = json.loads((root / "state.json").read_text())
    result = json.loads((root / "last-result.json").read_text())
    boot_id = pathlib.Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    run_id = result["run_id"]
    events = result["events"]
    if not run_id or run_id == previous_id:
        raise ValueError("aucun nouveau résultat terminé")
    if result.get("boot_id") != boot_id:
        raise ValueError("résultat d'un précédent démarrage")
    if current.get("run_id") != run_id or current.get("events") != events:
        raise ValueError("le résultat ne correspond pas à l'exécution courante")
    if events[-1]["status"] != "SUCCESS":
        raise ValueError("la mise à jour n'a pas réussi")
    statuses = {event["status"] for event in events}
    if not {"RUNNING_DNF", "RUNNING_FLATPAK", "RUNNING_FIRMWARE"}.issubset(statuses):
        raise ValueError("toutes les étapes n'ont pas été exécutées")
    print(f"{run_id}:{len(events) - 1}")
except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
    print(f"Validation de la mise à jour impossible : {error}", file=sys.stderr)
    sys.exit(1)
PYTHON
}



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

[ ! -e /run/ostree-booted ] || die "Les variantes immuables (Kinoite) ne sont pas prises en charge."

ok "$(cat /etc/fedora-release)"
# Sérialiser les installations et attendre une transaction déjà en cours.
[ ! -L /var/lib/fedora-auto-update ] || die "Dossier d'état symbolique refusé"
install -d -o root -g root -m 0755 /var/lib/fedora-auto-update
[ ! -L /var/lib/fedora-auto-update/install.lock ] || die "Verrou d'installation invalide"
[ ! -L /var/lib/fedora-auto-update/update.lock ] || die "Verrou de mise à jour invalide"
exec 8>/var/lib/fedora-auto-update/install.lock
info "Attente d'une éventuelle installation en cours"
flock -x 8
exec 9>/var/lib/fedora-auto-update/update.lock
info "Attente de la fin d'une éventuelle mise à jour en cours"
flock -x 9

STAGE="$(mktemp -d /var/tmp/fedora-auto-update-install.XXXXXX)"
chmod 755 "$STAGE"
mkdir -m 700 "$STAGE/backup"
DEPLOYED=()
COMMITTED=0

# Le renommage évite de tronquer un fichier encore ouvert par Bash.
# Les écritures dans le home sont faites avec les droits de l'utilisateur.
atomic_put() {
    local source=$1 destination=$2 mode=$3 scope=$4
    local writer
    writer="$(cat <<'WRITER'
        set -eu
        destination=$1
        mode=$2
        temporary=$(mktemp "${destination}.XXXXXX")
        trap 'rm -f -- "$temporary"' EXIT
        cat > "$temporary"
        chmod "$mode" "$temporary"
        mv -fT -- "$temporary" "$destination"
WRITER
    )"
    if [ "$scope" = user ]; then
        run_as_user bash -c "$writer" bash "$destination" "$mode" < "$source"
    else
        bash -c "$writer" bash "$destination" "$mode" < "$source"
    fi
}

deploy() {
    local source=$1 destination=$2 mode=$3 scope=$4
    local index=${#DEPLOYED[@]}
    [ ! -L "$destination" ] || die "Destination symbolique refusée : $destination"
    if [ -e "$destination" ]; then
        [ -f "$destination" ] || die "Destination non régulière : $destination"
        cat -- "$destination" > "$STAGE/backup/$index"
        stat -c '%a' "$destination" > "$STAGE/backup/$index.mode"
    fi
    DEPLOYED+=("$destination|$scope")
    atomic_put "$source" "$destination" "$mode" "$scope"
}

finish_install() {
    local rc=$?
    trap - EXIT
    if [ "$COMMITTED" -eq 0 ] && [ "${#DEPLOYED[@]}" -gt 0 ]; then
        warn "Échec du déploiement : restauration des fichiers précédents"
        local index destination scope
        for ((index=${#DEPLOYED[@]}-1; index>=0; index--)); do
            IFS='|' read -r destination scope <<< "${DEPLOYED[index]}"
            if [ -f "$STAGE/backup/$index" ]; then
                atomic_put "$STAGE/backup/$index" "$destination"                     "$(cat "$STAGE/backup/$index.mode")" "$scope" ||
                    warn "Restauration impossible : $destination"
            elif [ "$scope" = user ]; then
                run_as_user rm -f -- "$destination" || true
            else
                rm -f -- "$destination" || true
            fi
        done
        systemctl daemon-reload || true
        if [ -S "$USER_BUS" ]; then run_user_systemctl daemon-reload || true; fi
    fi
    if [ "$rc" -ne 0 ] && [ -n "${HEALTH_REPORT:-}" ]; then
        printf '\nInstallateur terminé avec le code %s le %s. Voir les messages précédents.\n' \
            "$rc" "$(date --iso-8601=seconds)" >> "$HEALTH_REPORT"
    fi
    rm -rf -- "$STAGE"
    exit "$rc"
}
trap finish_install EXIT
trap 'exit 130' INT
trap 'exit 143' TERM


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

for file in "${REQUIRED_FILES[@]}"; do
    install -m 0644 "$file" "$STAGE/$(basename "$file")"
done
chmod 755 "$STAGE/fedora-auto-update" "$STAGE/fedora-update-notifier"
SYSTEM_SCRIPT_SRC="$STAGE/fedora-auto-update"
SYSTEM_SERVICE_SRC="$STAGE/fedora-auto-update.service"
SYSTEM_TIMER_SRC="$STAGE/fedora-auto-update.timer"
USER_NOTIFIER_SRC="$STAGE/fedora-update-notifier"
USER_SERVICE_SRC="$STAGE/fedora-update-notifier.service"
USER_TIMER_SRC="$STAGE/fedora-update-notifier.timer"
ok "Tous les fichiers source sont présents"

# Dépendances
REQUIRED_PACKAGES=(
    dnf5
    flatpak
    fwupd
    libnotify
    python3
    util-linux
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
    dnf5
    flatpak
    fwupdmgr
    notify-send
    python3
    busctl
    systemctl
    systemd-analyze
    flock
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
# Vérification préalable avec des exécutables déjà présents dans le staging.
mkdir "$STAGE/verify"
sed "s|^ExecStart=.*|ExecStart=$SYSTEM_SCRIPT_SRC|"     "$SYSTEM_SERVICE_SRC" > "$STAGE/verify/fedora-auto-update.service"
cp "$SYSTEM_TIMER_SRC" "$STAGE/verify/"
sed "s|^ExecStart=.*|ExecStart=$USER_NOTIFIER_SRC|"     "$USER_SERVICE_SRC" > "$STAGE/verify/fedora-update-notifier.service"
cp "$USER_TIMER_SRC" "$STAGE/verify/"
systemd-analyze verify "$STAGE/verify/fedora-auto-update.service"     "$STAGE/verify/fedora-auto-update.timer"
run_as_user systemd-analyze --user verify "$STAGE/verify/fedora-update-notifier.service"     "$STAGE/verify/fedora-update-notifier.timer"


# Installation système
info "Installation des fichiers système"
install -d -o root -g root -m 0755 /usr/local/sbin /etc/systemd/system /var/lib/fedora-auto-update

deploy "$SYSTEM_SCRIPT_SRC" "$SYSTEM_SCRIPT_DST" 0755 system

deploy "$SYSTEM_SERVICE_SRC" "$SYSTEM_SERVICE_DST" 0644 system

deploy "$SYSTEM_TIMER_SRC" "$SYSTEM_TIMER_DST" 0644 system

ok "Fichiers système installés"

# Installation utilisateur
info "Installation des fichiers utilisateur"

sudo -u "$INSTALL_USER" install -d -m 0755 \
    "$USER_BIN_DIR"

sudo -u "$INSTALL_USER" install -d -m 0755 \
    "$USER_SYSTEMD_DIR"

deploy "$USER_NOTIFIER_SRC" "$USER_NOTIFIER_DST" 0755 user

deploy "$USER_SERVICE_SRC" "$USER_SERVICE_DST" 0644 user

deploy "$USER_TIMER_SRC" "$USER_TIMER_DST" 0644 user

ok "Fichiers utilisateur installés"

# Validation systemd
systemd-analyze verify \
    "$SYSTEM_SERVICE_DST" \
    "$SYSTEM_TIMER_DST" >/dev/null ||
    die "Validation des unités systemd système échouée."

ok "Unités systemd système valides"

# Vérifier aussi les unités de la session utilisateur avant activation.
run_as_user systemd-analyze --user verify \
    "$USER_SERVICE_DST" "$USER_TIMER_DST" ||
    die "Validation des unités systemd utilisateur échouée."

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

for file in "$USER_NOTIFIER_DST" "$USER_SERVICE_DST" "$USER_TIMER_DST"; do
    [ "$(stat -c '%u' "$file")" = "$USER_UID" ] || die "Propriétaire incorrect : $file"
done
# Vérifier les six contenus, pas seulement leur présence.
for pair in \
    "$SYSTEM_SCRIPT_SRC|$SYSTEM_SCRIPT_DST" \
    "$SYSTEM_SERVICE_SRC|$SYSTEM_SERVICE_DST" \
    "$SYSTEM_TIMER_SRC|$SYSTEM_TIMER_DST" \
    "$USER_NOTIFIER_SRC|$USER_NOTIFIER_DST" \
    "$USER_SERVICE_SRC|$USER_SERVICE_DST" \
    "$USER_TIMER_SRC|$USER_TIMER_DST"; do
    IFS='|' read -r source destination <<< "$pair"
    cmp -s "$source" "$destination" || die "Contenu installé incorrect : $destination"
done
[ "$(stat -c '%a' "$USER_NOTIFIER_DST")" = 755 ] || die "Permissions du notificateur incorrectes"
for file in "$USER_SERVICE_DST" "$USER_TIMER_DST"; do
    [ "$(stat -c '%a' "$file")" = 644 ] || die "Permissions incorrectes : $file"
done
ok "Contenus et permissions des six fichiers vérifiés"

# Les fichiers sont validés. Les overrides systemd et l'état sont conservés.
systemctl daemon-reload
COMMITTED=1
PREVIOUS_RUN_ID="$(cat /var/lib/fedora-auto-update/run-id 2>/dev/null || true)"
HEALTH_REPORT="/var/lib/fedora-auto-update/installation-check.txt"
printf 'Contrôle démarré le %s — résultat en attente.\n' "$(date --iso-8601=seconds)" > "$HEALTH_REPORT"
flock -u 9
exec 9>&-
# Libérer les verrous avant de demander une nouvelle exécution du service.
flock -u 8
exec 8>&-

# Activer hors ligne : les notifications seront prêtes à la prochaine connexion.
run_user_systemctl --no-reload enable fedora-update-notifier.timer

# Recharger et activer le timer système
systemctl daemon-reload ||
    die "Échec de systemctl daemon-reload"

systemctl enable fedora-auto-update.timer

# Vérifier qu'une session utilisateur systemd est disponible

if [ ! -S "$USER_BUS" ]; then
    warn "Bus D-Bus utilisateur indisponible."
    warn "Le timer de notification est activé pour la prochaine connexion."
    USER_SYSTEMD_OK=0
else
    USER_SYSTEMD_OK=1

    run_user_systemctl daemon-reload ||
        die "Échec du daemon-reload systemd utilisateur"

    run_user_systemctl reset-failed fedora-update-notifier.service ||
        die "Impossible de réinitialiser le service de notification"

    run_user_systemctl restart fedora-update-notifier.timer ||
        die "Impossible d'activer le timer utilisateur"

    run_user_systemctl is-enabled fedora-update-notifier.timer >/dev/null 2>&1 ||
        die "Le timer utilisateur n'est pas activé"

    run_user_systemctl is-active fedora-update-notifier.timer >/dev/null 2>&1 ||
        die "Le timer utilisateur n'est pas actif"

    ok "Timer de notification actif"
fi

# Test fonctionnel de notification
if [ "$USER_SYSTEMD_OK" -eq 1 ]; then
    info "Test de fin d'installation : notification KDE"

    if run_as_user notify-send --app-name="Fedora Update" --icon=system-software-update \
        "Installation terminée" "Les mises à jour automatiques sont configurées."; then
        ok "Test de notification exécuté"
    else
        warn "Le test de notification a échoué."
        warn "L'installation principale reste terminée."
    fi
fi

# Le contrôle attend le service réel, sans lancer les gestionnaires de paquets
# une seconde fois. Les erreurs de fonctionnement ne désinstallent pas l'outil.
info "Vérification fonctionnelle : attente de la mise à jour réelle"
info "Cette étape peut durer plusieurs minutes. Logs : journalctl -fu fedora-auto-update.service"
systemctl reset-failed fedora-auto-update.service ||
    die "Impossible de réinitialiser l'état du service de mise à jour"
UPDATE_START_OK=1
systemctl start fedora-auto-update.service || UPDATE_START_OK=0

systemctl restart fedora-auto-update.timer ||
    die "Impossible d'activer fedora-auto-update.timer"

CHECK_FAILED=0
SYSTEM_TIMER_CHECK="ÉCHEC"
if systemctl is-enabled fedora-auto-update.timer >/dev/null 2>&1 &&
   systemctl is-active fedora-auto-update.timer >/dev/null 2>&1; then
    SYSTEM_TIMER_CHECK="VALIDÉ"
else
    CHECK_FAILED=1
fi

UPDATE_CHECK="ÉCHEC — consulter last-result.txt et journalctl"
EXPECTED_EVENT=""
if [ "$UPDATE_START_OK" -eq 1 ] &&
   [ "$(systemctl show fedora-auto-update.service -p Result --value)" = success ] &&
   EXPECTED_EVENT="$(verify_update_receipt /var/lib/fedora-auto-update "$PREVIOUS_RUN_ID")"; then
    UPDATE_CHECK="VALIDÉ — nouvelle exécution DNF, Flatpak et firmware terminée avec succès"
else
    CHECK_FAILED=1
fi

NOTIFICATION_CHECK="NON VÉRIFIÉ — session utilisateur indisponible"
if [ "$USER_SYSTEMD_OK" -eq 1 ]; then
    NOTIFICATION_CHECK="ÉCHEC ou résultat non confirmé"
    # Tester le vrai service utilisateur et vérifier qu'il a acquitté le résultat.
    if run_user_systemctl is-active fedora-update-notifier.timer >/dev/null 2>&1 &&
       run_user_systemctl is-enabled fedora-update-notifier.timer >/dev/null 2>&1 &&
       run_user_systemctl start fedora-update-notifier.service &&
       [ "$(run_user_systemctl show fedora-update-notifier.service -p Result --value)" = success ] &&
       [ -n "$EXPECTED_EVENT" ]; then
        # Le service peut utiliser un XDG_CACHE_HOME personnalisé dans son environnement.
        NOTIFIER_CACHE="$USER_HOME/.cache"
        USER_MANAGER_ENV="$(run_user_systemctl show-environment)"
        while IFS= read -r entry; do
            case "$entry" in XDG_CACHE_HOME=/*) NOTIFIER_CACHE="${entry#XDG_CACHE_HOME=}" ;; esac
        done <<< "$USER_MANAGER_ENV"
        if [ "$(run_as_user cat "$NOTIFIER_CACHE/fedora-auto-update/last-event" 2>/dev/null || true)" = "$EXPECTED_EVENT" ]; then
            NOTIFICATION_CHECK="VALIDÉ — événement final acquitté par le notificateur"
        fi
    fi
fi
case "$NOTIFICATION_CHECK" in VALIDÉ*) ;; *) CHECK_FAILED=1 ;; esac

if [ "$CHECK_FAILED" -eq 0 ]; then
    OVERALL="CONTRÔLES AUTOMATIQUES VALIDÉS"
else
    OVERALL="INSTALLATION EFFECTUÉE — CONTRÔLE INCOMPLET OU EN ÉCHEC"
fi
REPORT_TMP="$(mktemp /var/lib/fedora-auto-update/.installation-check.XXXXXX)"
{
    printf '%s\n' "$OVERALL"
    printf 'Date : %s\n' "$(date --iso-8601=seconds)"
    printf 'Fichiers, contenus, permissions et unités : VALIDÉS\n'
    printf 'Timer système : %s\n' "$SYSTEM_TIMER_CHECK"
    printf 'Mise à jour réelle : %s\n' "$UPDATE_CHECK"
    printf 'Notifications et timer utilisateur : %s\n' "$NOTIFICATION_CHECK"
    printf '\nL’affichage visuel KDE ne peut pas être confirmé automatiquement (mode Ne pas déranger, réglages KDE).\n'
    printf 'Ce bilan décrit le contrôle effectué maintenant, pas une garantie des exécutions futures.\n'
} > "$REPORT_TMP"
chmod 644 "$REPORT_TMP"
mv -fT "$REPORT_TMP" "$HEALTH_REPORT"

echo
cat "$HEALTH_REPORT"
echo
echo "Rapport : cat $HEALTH_REPORT"
echo "Résultat : cat /var/lib/fedora-auto-update/last-result.txt"
echo "Logs : journalctl -u fedora-auto-update.service"
echo "Notifications : journalctl --user -u fedora-update-notifier.service"
echo
if [ "$CHECK_FAILED" -ne 0 ]; then
    warn "L'outil reste installé. Corrige les erreurs indiquées puis relance sudo ./install.sh."
    exit 2
fi
