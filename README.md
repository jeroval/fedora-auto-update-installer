# Fedora Auto Update Installer

Automatise les mises à jour sur **Fedora KDE Plasma**.

Le programme met automatiquement à jour :

- Fedora et les paquets RPM
- Le kernel Linux
- KDE Plasma
- Les applications Flatpak installées au niveau système (pas celles installées avec `--user`)
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

Une notification de test est envoyée si la session graphique est disponible, sans modifier le résultat de la dernière mise à jour.

À la fin de l'installation, une mise à jour est automatiquement demandée à
systemd. **L'installateur attend sa fin pour contrôler le fonctionnement réel** :
cela peut prendre plusieurs minutes, dans la limite du délai du service
(actuellement une heure). Les logs sont consultables dans un autre terminal
avec `journalctl -fu fedora-auto-update.service`.
Si une mise à jour est déjà en cours, l'installateur attend sa fin sans l'interrompre.
Les notifications KDE indiquent le démarrage / DNF (1/3), Flatpak (2/3),
le firmware (3/3), puis le succès ou l'erreur. Leur envoi est vérifié environ
toutes les dix secondes lorsque la session graphique est disponible.

## Contrôle fonctionnel de fin d'installation

Le bilan final vérifie :

- Les contenus des six fichiers installés, leurs propriétaires, leurs permissions et les unités systemd.
- L'activation du timer système.
- La réussite d'une **nouvelle** exécution DNF, Flatpak et firmware, distincte d'un ancien résultat.
- L'activation du timer utilisateur et l'exécution du véritable service de notification.
- L'acquittement de l'événement final par le notificateur.

`CONTRÔLES AUTOMATIQUES VALIDÉS` apparaît uniquement si tous ces contrôles
réussissent. Si une session utilisateur manque, si la mise à jour échoue ou
si le résultat n'a pas été notifié, le bilan indique un contrôle incomplet
ou en échec et l'installateur retourne le code 2. L'outil reste installé.

Le rapport daté est consultable avec :

```bash
cat /var/lib/fedora-auto-update/installation-check.txt
```

Un acquittement confirme que la commande de notification a réussi ; il ne prouve
pas que la fenêtre a été visible (mode Ne pas déranger, réglages KDE).
Le bilan est ponctuel : il ne garantit pas les prochaines exécutions.
La première notification de test annonce la configuration, pas le succès du
contrôle final. Après correction d'une erreur, relancez `sudo ./install.sh`.

## Mettre à jour l'outil lui-même

Après avoir récupéré la nouvelle version du projet, relancez :

```bash
sudo ./install.sh
```

L'installateur attend les exécutions en cours, prépare une copie des sources et
vérifie leur syntaxe ainsi que les unités systemd. Il remplace les fichiers par
renommage atomique, sans tronquer un script en cours de lecture.
Un échec pendant le remplacement, les contrôles des fichiers installés ou le
premier rechargement système restaure les fichiers précédents.
Les résultats et les overrides systemd ne sont pas effacés.

Une fois les fichiers validés et déployés, un échec d'activation des timers est
signalé ; les nouveaux fichiers restent installés et une relance de l'installateur
permet de réessayer. La restauration concerne les fichiers déployés, pas les
dépendances RPM installées. Une coupure électrique pendant le déploiement nécessite
de relancer l'installateur ; le remplacement des six fichiers n'est pas une
transaction atomique unique.

Les scripts système sont installés avec le propriétaire root et les permissions
0755 (scripts) / 0644 (unités). Les écritures dans le dossier personnel sont
effectuées avec les droits de l'utilisateur. Les chemins de recherche des
commandes privilégiées sont fixés aux répertoires système. Les liens symboliques
aux emplacements des fichiers déployés sont refusés.

## Fonctionnement

Une vérification des mises à jour est lancée :

- À la fin de l'installation
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
cat /var/lib/fedora-auto-update/details
```

Le fichier `status` indique l'étape courante ou `SUCCESS` / `ERROR`.
Le document `state.json` contient toutes les étapes de la dernière exécution ;
le notificateur les lit sans risque de mélanger deux états.
Ces fichiers restent disponibles après un redémarrage.
Le dernier résultat **terminé** reste consultable pendant la tentative suivante :

```bash
cat /var/lib/fedora-auto-update/last-result.txt
```

Sa version structurée est `last-result.json`. Le dossier `history/` conserve
les 20 derniers résultats terminés, y compris les exécutions interrompues
détectées lors de la tentative suivante.

Les compteurs comparent les installations avant et après chaque étape :
les RPM nouvellement installés ou remplacés (dont les kernels), et les
applications Flatpak dont le commit a changé ou qui ont été installées.
Les runtimes Flatpak sont mis à jour, mais ne sont pas comptés comme applications.
En cas d'échec partiel, seuls les changements observés sont comptés.
Une lecture impossible est affichée comme « indisponible », jamais comme zéro.
Évitez de lancer un autre gestionnaire de mises à jour en même temps :
ses changements pourraient aussi apparaître dans cette comparaison.

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

## Fiabilité et nouvelles tentatives

L'installation s'arrête si une commande obligatoire échoue. Les scripts utilisent
des verrous pour éviter les exécutions simultanées et les notifications en double.
Une erreur DNF n'empêche pas de tenter Flatpak et fwupd ; le résultat global
reste en erreur si l'une des étapes échoue.
Le service réessaie après dix minutes, dans la limite de trois démarrages
sur une fenêtre de 24 heures. La planification quotidienne reste active.
Après avoir corrigé un problème, une relance immédiate est possible :

```bash
sudo systemctl reset-failed fedora-auto-update.service
sudo systemctl start fedora-auto-update.service
```

Avant les transactions, un seuil de 200 Mio libres est vérifié sur `/`, `/var`
et `/boot`. En dessous, aucune transaction n'est lancée et une recommandation
demande de libérer de l'espace. Cet échec ne provoque pas de reprise rapprochée
(code 78) ; la vérification quotidienne reste prévue. Ce seuil est un garde-fou,
pas une estimation de la taille des téléchargements ou de la transaction.

Les autres erreurs restent réessayables : le script ne prétend pas distinguer
une panne réseau d'une erreur de dépôt à partir d'un code générique.
Chaque reprise revérifie les trois gestionnaires, qui traitent les mises à jour
encore disponibles. Le script ne mémorise pas de point de reprise par étape.
Après trois échecs consécutifs, le résultat recommande de consulter les logs.

L'état et le journal de la dernière tentative sont conservés dans
`/var/lib/fedora-auto-update`. Les nouveaux fichiers `last-run.log` sont limités
aux dix premiers Mio ; cinq précédents journaux sont conservés dans `logs/`.
Les sorties complètes sont aussi transmises à journald, selon sa rétention.
Une interruption normale publie une erreur. Après une coupure électrique, le
notificateur reconnaît le changement de démarrage et signale l'interruption ;
la prochaine exécution archive la tentative interrompue.

Les notifications des étapes de la dernière exécution sont mémorisées,
y compris si les étapes se terminent entre deux vérifications du notificateur.
Un envoi échoué est réessayé et les événements déjà envoyés sont ignorés.
Sans session graphique, le dernier résultat sera présenté à la connexion.
Les anciennes tentatives archivées ne sont pas rejouées dans les notifications.

L'absence de mise à jour firmware (code fwupd 2) est un succès.
L'option `--no-reboot-check` évite la demande de redémarrage du client fwupd.
Un redémarrage manuel peut être nécessaire pour appliquer le kernel
ou terminer certaines mises à jour firmware.

Fedora KDE classique avec DNF5 est pris en charge. Fedora Kinoite et
les autres variantes immuables ne le sont pas.

## Recommandations utilisateur

Une notification recommande un redémarrage manuel lorsque le kernel actif
diffère du kernel installé sélectionné par tri de version. Cette vérification
concerne `kernel-core` ; elle ne détecte pas tous les besoins de redémarrage
(glibc, services, kernels personnalisés ou firmwares).
Une même recommandation n'est envoyée qu'une fois par démarrage.
Elle reste également dans le résultat terminé.

Un manque d'espace disque, une exécution interrompue ou des échecs répétés
produisent un message adapté. Les demandes matérielles spécifiques à fwupd
restent à consulter dans ses logs : elles ne sont pas interprétées automatiquement.

## Validation

```bash
bash -n install.sh files/fedora-auto-update files/fedora-update-notifier
python3 -m unittest discover -s tests -v
```

Les tests simulent les gestionnaires de paquets et les notifications :
ils ne mettent pas à jour la machine. Une validation sur Fedora KDE reste
nécessaire pour vérifier les véritables transactions, les timers et l'affichage KDE.
