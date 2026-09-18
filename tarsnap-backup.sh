#!/bin/sh
#
# tarsnap-backup.sh
#
# Rotation grand-père / père / fils : schéma de rétention classique, hérité
# de la rotation de bandes magnétiques, ici réimplémenté en sh POSIX.
#
# Ordre volontaire : on crée AVANT de détruire. Si tarsnap échoue (réseau,
# quota, clé), set -e coupe le script et aucune archive n'est supprimée.
# Le pire cas est donc "les vieilles archives s'accumulent", jamais
# le comportement : "j'ai purgé et je n'ai rien de neuf".
#
# Options :
#   -n, -d, --dry-run      ne crée aucune archive et ne supprime rien
#   -v, --verbose          détaille la décision prise pour chaque archive
#   -s, --snapshot-name N  crée une archive nommée, hors rotation
#   -o, --orphans          liste les archives hors de portée de la rotation
#   -h, --help             affiche l'aide
#
# Le man tarsnap interdit deux opérations de création ou de suppression
# concurrentes avec la même clé : le script pose donc lui-même un verrou
#

# -e : on sort à la première erreur
# -u : une variable non définie est une erreur
# -f : pas de glob sur les expansions non quotées ($BACKUP_DIRS, motifs
#      d'exclusion). 

set -euf

#################
# CONFIGURATION #
#################

# --- Chemins absolus des binaires ---
#
# Les chemins sont en dur pour ne pas dépendre du $PATH de l'appelant, que ce
# soit cron, systemd ou un sudo mal réglé. Ils sont donnés pour Debian avec
# usrmerge, donc tout sous /usr/bin. 
#
TARSNAP_BIN="/usr/bin/tarsnap"
DATE_BIN="/usr/bin/date"
UNAME_BIN="/usr/bin/uname"
LOCALE_BIN="/usr/bin/locale"
GREP_BIN="/usr/bin/grep"
DPKG_BIN="/usr/bin/dpkg"
APT_BIN="/usr/bin/apt"
FLOCK_BIN="/usr/bin/flock"

# --- Comportement par défaut, écrasable par les options ---
DRY=0            # 1 = simulation complète, ne crée ni ne supprime aucune archive
VERBOSE=0        # 1 = détaille chaque décision et passe -v à tarsnap
SNAPSHOT_NAME="" # non vide = archive nommée, hors rotation
ORPHANS=0        # 1 = liste les archives hors rotation, puis sort

# --- Tarsnap ---
# Chemin de la clef privée de Tarsnap.
# Laisser vide pour se reposer sur le keyfile déclaré dans tarsnap.conf.
TARSNAP_KEY="/root/tarsnap.key"

# Répertoires sauvegardés (séparés par des espaces)
BACKUP_DIRS="/root /boot /var/www /etc"

# Motifs d'exclusion, séparés par des espaces. Deux formes acceptées :
#   - motif globbé ("*/tmp/*"), passé tel quel à tarsnap
#   - chemin absolu ("/var/www/html/APOD"), ancré donc sans effet de bord.
#     tarsnap retire le / de tête des noms d'entrée (sauf avec -P), la
#     conversion est faite plus bas.
BACKUP_EXCLUDE="*/tmp/* /var/www/html/APOD"

# Verrou d'exécution. Dans /run et pas /tmp ni /run/lock, qui sont en 1777 :
# n'importe quel utilisateur local pourrait y tenir le verrou et bloquer les
# sauvegardes. /run est en 755 root.
LOCK_FILE="/run/tarsnap-backup.lock"

# Inventaire des paquets, régénéré avant chaque sauvegarde
PKG_SELECTIONS="/root/pkg-selections.txt"
PKG_LIST="/root/pkg-list.txt"

# --- Rétention : schéma grand-père / père / fils ---
# Les trois fenêtres sont CUMULÉES : elles se succèdent au lieu de se
# recouvrir. Chaque palier prend le relais là où le précédent s'arrête, et
# la couverture totale est donc DAILY jours + WEEKLY semaines + MONTHLY mois.
DAILY=90    # tout est conservé sur les N premiers jours
WEEKLY=12   # puis, sur les N semaines suivantes, celles tombant un $DOW
MONTHLY=48  # puis, sur les N mois suivants, celles tombant un $DOM
DOW=1       # jour de la semaine conservé (0 = dimanche, 1 = lundi)
DOM=1       # jour du mois conservé

###############################################################################
# FIN DE LA CONFIGURATION
###############################################################################

# Déclaration des fonctions 

# Code de sortie en argument : 0 pour --help, 1 pour une option invalide.
usage() {
    cat >&2 <<EOF
usage: ${0##*/} [-d|-n|--dry-run] [-v|--verbose] [-h|--help]
       ${0##*/} [-s|--snapshot-name] NOM
       ${0##*/} [-o|--orphans]

  -d, -n, --dry-run      simulation complète : rien n'est créé ni supprimé,
                         seule la commande de purge est affichée. La création
                         est simulée par tarsnap --dry-run, qui lit les
                         fichiers, donc c'est aussi long qu'un run réel.
  -v, --verbose          détaille la décision prise pour chaque archive
  -s, --snapshot-name N  crée une archive suffixée par N, puis sort sans faire
                         de rotation. Son nom la rend définitivement intouchable
                         par la purge. Accepte aussi --snapshot-name=N.
  -o, --orphans          liste les archives hors de portée de la rotation,
                         orphelines et partielles, puis sort sans rien
                         sauvegarder ni supprimer. Lecture seule.
  -h, --help             affiche cette aide
EOF
    exit "${1:-1}"
}

# Affiche seulement en mode verbeux.
# printf et pas echo : le comportement d'echo sur un backslash ou un
# argument commençant par "-" n'est pas spécifié par POSIX, et dash
# interprète les échappements là où bash ne le fait pas.
# Le "return 0" est indispensable : sans lui, un [ ] faux ferait sortir
# le script à cause de set -e.
say() {
    [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$*"
    return 0
}

die() {
    printf 'ERREUR: %s\n' "$*" >&2
    exit 1
}

# prebackup : tout ce qui doit être préparé avant que tarsnap ne lise les
# fichiers. Inventaires, dumps de bases, export de configuration, appel à un
# script externe.
#
# ATTENTION : prebackup est exécutée AUSSI en --dry-run, et c'est voulu. Une
# simulation qui ne préparerait pas les mêmes fichiers ne simulerait pas
# grand-chose. Conséquence pratique : si vous y placez un dump de plusieurs
# gigaoctets, commentez-le avant d'enchaîner les essais à blanc, sinon chaque
# --dry-run le rejoue en entier.
#
# La fonction doit rendre 0. Toute autre valeur arrête le script AVANT la
# création de l'archive, donc avant la moindre suppression : mieux vaut ne
# rien sauvegarder que sauvegarder une base à moitié dumpée.
prebackup() {
    say "Inventaire des paquets installés."
    "$DPKG_BIN" --get-selections > "$PKG_SELECTIONS"
    "$APT_BIN" list --installed 2>/dev/null > "$PKG_LIST"

    # Exemples à décommenter et à adapter. Déclarez le chemin absolu du
    # binaire en tête de script, comme les autres, plutôt que de vous en
    # remettre au $PATH.
    #
    # Dump MySQL / MariaDB. Les identifiants vont dans ~/.my.cnf en 0600,
    # jamais sur la ligne de commande où ps les rendrait visibles de tous.
    # say "Dump des bases MySQL."
    # /usr/bin/mysqldump --all-databases --single-transaction --quick \
    #     --events --routines > /root/dumps/mysql-all.sql
    #
    # Dump PostgreSQL.
    # say "Dump des bases PostgreSQL."
    # su - postgres -c /usr/bin/pg_dumpall > /root/dumps/postgres-all.sql
    #
    # Table de partitions, pour savoir repartir d un disque nu.
    # /usr/sbin/sfdisk --dump /dev/sda > /root/partitions-sda.txt
    #
    # Script externe. Son échec remonte ici et arrête la sauvegarde.
    # /usr/local/sbin/pre-backup-hook.sh

    return 0
}

# postbackup : le pendant de prebackup, exécutée une fois l'archive créée,
# snapshot compris, et avant la rotation. Nettoyage des dumps temporaires,
# notification, redémarrage d'un service arrêté par prebackup.
#
# Mêmes règles : exécutée elle aussi en --dry-run, et doit rendre 0. Un échec
# ici laisse l'archive en place et saute la rotation, donc les anciennes
# archives s'accumulent. C'est le sens de panne souhaitable.
postbackup() {
    # say "Nettoyage des dumps."
    # rm -f /root/dumps/mysql-all.sql
    #
    # say "Notification."
    # /usr/local/sbin/post-backup-hook.sh

    return 0
}

# Affiche une famille d'archives, puis la commande de suppression qui lui
# correspond. Rien n'est supprimé : la commande est seulement imprimée, à
# relire puis à coller soi-même.
orphans_section() {
    _title=$1
    _list=$2

    printf -- '--- %s ---\n' "$_title"
    if [ -z "$_list" ]; then
        printf '  (aucune)\n\n'
        return 0
    fi
    for _a in $_list; do
        printf '  %s\n' "$_a"
    done
    printf '\n  Suppression, a relire avant de la coller :\n'
    if [ -n "$TARSNAP_KEYOPT" ]; then
        printf '  %s %s -d' "$TARSNAP_BIN" "$TARSNAP_KEYOPT"
    else
        printf '  %s -d' "$TARSNAP_BIN"
    fi
    for _a in $_list; do
        printf -- ' -f %s' "$_a"
    done
    printf '\n\n'
    return 0
}

# Liste les archives que la rotation ne touchera jamais. Lecture seule :
# aucune archive n'est créée ni supprimée.
#
# Deux familles, pour deux raisons distinctes.
#
# Les orphelines : leur nom ne correspond pas au motif
# "hostname-AAAA-MM-JJ_HH-MM-SS", donc la purge ne les regarde même pas.
# Snapshots créés avec -s, archives faites à la main, archives d'une autre
# machine partageant la même clé, archives datant d'un hostname précédent.
#
# Les partielles : suffixées .part, vestiges d'une exécution interrompue dont
# tarsnap a récupéré un checkpoint. Elles comptent pour la déduplication et
# peuvent contenir des données qui ne sont nulle part ailleurs.
list_orphans() {
    say "Récupération de la liste des archives."
    # shellcheck disable=SC2086
    _all=$("$TARSNAP_BIN" $TARSNAP_KEYOPT --list-archives)

    _orphans=""
    _parts=""
    for _a in $_all; do
        case "$_a" in
            *.part)
                _parts="${_parts} ${_a}" ;;
            "${COMPUTER}-"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9]-[0-9][0-9])
                ;;
            *)
                _orphans="${_orphans} ${_a}" ;;
        esac
    done

    printf 'Archives hors de portee de la rotation, hostname "%s".\n\n' "$COMPUTER"
    orphans_section "Orphelines : nom hors motif, jamais purgees" "$_orphans"
    orphans_section "Partielles : execution interrompue, checkpoint recupere" "$_parts"
    return 0
}

# getopts POSIX ne connaît que les options d'un caractère : on traduit les
# formes longues avant de le lancer, en acceptant un ou deux tirets.
for arg do
    shift
    case "$arg" in
        --help|-help)       usage 0 ;;
        --dry-run|-dry-run) set -- "$@" -d ;;
        --verbose|-verbose) set -- "$@" -v ;;
        # Forme accolée : on découpe nous-mêmes sur le premier "=".
        --snapshot-name=*|-snapshot-name=*)
                            set -- "$@" -s "${arg#*=}" ;;
        # Forme séparée : on émet juste -s, la valeur suit dans $@ et
        # c'est getopts qui la ramassera, y compris pour râler si elle manque.
        --snapshot-name|-snapshot-name)
                            set -- "$@" -s ;;
        --orphans|-orphans) set -- "$@" -o ;;
        *)                  set -- "$@" "$arg" ;;
    esac
done

# Attention : le -d du script veut dire "ne supprime rien", à l'exact
# opposé du -d de tarsnap qui, lui, supprime. -n est accepté en synonyme,
# c'est la forme la moins ambiguë des deux.
while getopts "dhnovs:" option; do
    case "$option" in
        d|n) DRY=1 ;;
        h) usage 0 ;;
        o) ORPHANS=1 ;;
        s) SNAPSHOT_NAME=$OPTARG ;;
        v) VERBOSE=1 ;;
        *) usage 1 ;;
    esac
done

###############################################################################
# GARDE-FOUS
###############################################################################

# Tous les binaires configurés doivent être exécutables.
for bin in "$TARSNAP_BIN" "$DATE_BIN" "$UNAME_BIN" "$LOCALE_BIN" \
           "$GREP_BIN" "$DPKG_BIN" "$APT_BIN" "$FLOCK_BIN"; do
    [ -x "$bin" ] || die "binaire absent ou non exécutable: $bin"
done

# Le nom de snapshot finit dans un nom d'archive : on interdit tout ce qui
# introduirait un espace ou un caractère exotique. Liste explicite plutôt
# qu'un intervalle [A-Za-z], dont le contenu dépend de la locale.
case "$SNAPSHOT_NAME" in
    "") ;;
    *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-]*)
        die "nom de snapshot invalide, caractères autorisés: A-Z a-z 0-9 _ -" ;;
esac

# La clé doit être lisible, sauf si on délègue à tarsnap.conf.
if [ -n "$TARSNAP_KEY" ] && [ ! -r "$TARSNAP_KEY" ]; then
    die "clé tarsnap illisible: $TARSNAP_KEY"
fi

# Locale : on veut une sortie prédictible de tarsnap, apt et date.
if ! "$LOCALE_BIN" -a 2>/dev/null | "$GREP_BIN" -qix 'en_US\.utf-\?8'; then
    die "locale en_US.UTF-8 non générée sur ce système"
fi
unset LANGUAGE          # GNU gettext peut surcharger LC_MESSAGES, on dégage
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
export LANG LC_ALL

# Options communes aux invocations de tarsnap. Volontairement laissées non
# quotées à l'usage : elles doivent disparaître de la ligne de commande
# quand elles sont vides.
if [ -n "$TARSNAP_KEY" ]; then
    TARSNAP_KEYOPT="--keyfile $TARSNAP_KEY"
else
    TARSNAP_KEYOPT=""
fi

if [ "$VERBOSE" -eq 1 ]; then
    TARSNAP_MSGOPT="-v"
else
    # --quiet ne masque que quelques warnings ("Removing leading '/'", etc.).
    # C'est --no-print-stats qui neutralise la directive print-stats de
    # tarsnap.conf, responsable du bloc "All archives / This archive /
    # New data" imprimé sur stderr en modes c et d.
    TARSNAP_MSGOPT="--quiet --no-print-stats"
fi

COMPUTER=$("$UNAME_BIN" -n)

# Mode --orphans : lecture seule, donc aucun verrou. Le man tarsnap ne
# l'impose que pour deux opérations de création ou de suppression
# concurrentes, pas pour --list-archives : on peut donc interroger pendant
# qu'une sauvegarde tourne.
if [ "$ORPHANS" -eq 1 ]; then
    list_orphans
    exit 0
fi

# Verrou exclusif non bloquant. Il est porté par le descripteur 9, donc le
# noyau le libère à la mort du processus, y compris sur kill -9, OOM ou
# coupure de courant : pas de fichier fantôme à nettoyer à la main, et pas
# de course possible contrairement à un test d'existence suivi d'un touch.
exec 9>"$LOCK_FILE" || die "impossible d'ouvrir le verrou: $LOCK_FILE"
if ! "$FLOCK_BIN" -n 9; then
    die "une autre instance tourne déjà (verrou $LOCK_FILE)"
fi

###############################################################################
# ÉTAPE 1 : SAUVEGARDE
###############################################################################

# Appel nu, et surtout PAS "prebackup || die ..." ni "if ! prebackup".
# Placer une fonction dans une condition désactive set -e dans tout son corps :
# une commande qui échouerait au milieu serait ignorée, les suivantes
# s'exécuteraient quand même, et la fonction rendrait 0. Comportement vérifié
# identique sous dash et sous bash. Avec l'appel nu, set -e arrête le script
# sur la commande fautive, dont le message part dans le mail de cron.
prebackup

NOW=$("$DATE_BIN" +%Y-%m-%d_%H-%M-%S)
if [ -n "$SNAPSHOT_NAME" ]; then
    # Le suffixe fait sortir l'archive du motif testé par la rotation :
    # elle devient définitivement intouchable par la purge.
    NAME="${COMPUTER}-${NOW}_${SNAPSHOT_NAME}"
else
    NAME="${COMPUTER}-${NOW}"
fi

# Construction des --exclude dans les paramètres positionnels : c'est le
# seul "tableau" dont dispose sh POSIX.
set --
for pattern in $BACKUP_EXCLUDE; do
    case "$pattern" in
        /*)
            # Chemin absolu : on retire le / de tête pour coller aux noms
            # d'entrée réels, et on génère le motif du répertoire ainsi que
            # celui de son contenu.
            rel=${pattern#/}
            set -- "$@" --exclude="$rel" --exclude="$rel/*"
            ;;
        *)
            # Motif déjà relatif ou globbé, passé tel quel.
            set -- "$@" --exclude="$pattern"
            ;;
    esac
done

# En dry-run on simule aussi la création : tarsnap ne contacte pas le
# serveur, aucune archive n'est réellement créée. Deux variantes, choisies
# selon le niveau de verbosité demandé.
if [ "$DRY" -eq 1 ]; then
    # --dry-run et pas --dry-run-metadata. Cette dernière, ajoutée en 1.0.41,
    # serait pourtant bien plus rapide, elle ne lit aucune donnée. Elle échoue
    # dès que le cache de chunks est peuplé :
    #
    #   tarsnap: Programmer error: writetape_writechunk unexpectedly returned 0
    #   tarsnap: Error writing cached archive entry
    #
    # Reproduit en 1.0.41 sur chacun des quatre répertoires de BACKUP_DIRS pris
    # isolément, avec un cachedir issu d'une vraie sauvegarde. Le même appel
    # contre un cachedir fraîchement initialisé passe sans broncher, ce qui
    # isole le cache comme seule variable. print-stats n'y est pour rien :
    # l'échec se produit aussi avec --no-print-stats.
    #
    # Cause, côté source 1.0.41 : multitape_write.c:429 pose
    # no_chunkifiers = (dryrun == 2), ce qui prive de chunkifier les flux
    # initialisés lignes 517 à 521, alors que la couche chunks d->C est créée
    # sans condition sur dryrun ligne 503. writetape_ischunkpresent répond donc
    # "présent" là où writetape_writechunk rend 0, et ccache_entry.c:409 traite
    # ce 0 comme une erreur de programmation.
    #
    # Ne pas remettre l'option sans avoir vérifié que c'est corrigé en amont.
    set -- --dry-run "$@"
    say "Simulation de l'archive ${NAME}."
else
    say "Création de l'archive ${NAME}."
fi

# shellcheck disable=SC2086
"$TARSNAP_BIN" $TARSNAP_KEYOPT $TARSNAP_MSGOPT -c -f "$NAME" "$@" $BACKUP_DIRS

# Pendant de prebackup, joué que l'on soit en snapshot ou en sauvegarde
# normale : ce que prebackup a mis en place doit être défait dans tous les cas.
# Appel nu pour la même raison que plus haut.
postbackup

# Un snapshot est un acte ponctuel : on ne veut pas qu'en enchaîner trois
# avant une mise en prod déclenche trois purges.
if [ -n "$SNAPSHOT_NAME" ]; then
    if [ "$DRY" -eq 1 ]; then
        say "Snapshot ${NAME} simulé, rotation ignorée."
    else
        say "Snapshot ${NAME} créé, rotation ignorée."
    fi
    exit 0
fi

###############################################################################
# ÉTAPE 2 : ROTATION
###############################################################################

NOW_UNIX=$("$DATE_BIN" +%s)

# Bornes des trois fenêtres cumulées, exprimées en âge depuis maintenant.
# WEEKLY_SEC part de la fin du quotidien, et la borne mensuelle recule
# d'autant : une archive de 100 jours sort du quotidien (90 jours) mais
# tombe dans l'hebdomadaire, qui court de 90 à 174 jours.
#
# La variante à fenêtres absolues, où les trois seraient comptées depuis
# maintenant, imposerait l'invariant DAILY < WEEKLY*7 < MONTHLY*30. Faute
# de quoi un palier devient silencieusement inatteignable : avec DAILY=90
# et WEEKLY=12, les 84 jours de l'hebdomadaire tiennent entièrement dans
# les 90 jours du quotidien, et le palier père ne conserve jamais rien.
DAILY_SEC=$((DAILY * 86400))
WEEKLY_SEC=$((DAILY_SEC + WEEKLY * 604800))
MONTHLY_UNIX=$(($("$DATE_BIN" -d "-${MONTHLY} months" +%s) - WEEKLY_SEC))

say "Récupération de la liste des archives."
# shellcheck disable=SC2086
ARCHIVES=$("$TARSNAP_BIN" $TARSNAP_KEYOPT --list-archives)

# On repart d'un jeu de paramètres positionnels vide : il va servir
# d'accumulateur des "-f archive" à supprimer.
set --

# Le motif de nommage interdit l'espace, le découpage sur IFS est donc sûr.
for archive in $ARCHIVES; do

    # Garde-fou principal : on ne touche QUE ce qui respecte exactement
    # "hostname-AAAA-MM-JJ_HH-MM-SS". 
    # Tout le reste (snapshots crées à la main) est hors de portée du script.
    case "$archive" in
        *.part)
            # Archive interrompue (coupure de courant, réseau, ^Q) dont un
            # checkpoint a été récupéré. Elle compte pour la déduplication et
            # peut avoir de la valeur : on ne la supprime pas, on prévient.
            # Le message part sur stderr, donc dans le mail de cron.
            printf 'ATTENTION: archive partielle: %s\n' "$archive" >&2
            printf '  reste d une execution interrompue, a traiter a la main\n' >&2
            continue
            ;;
        "${COMPUTER}-"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9]-[0-9][0-9])
            ;;
        *)
            say "Hors motif, intouchable: $archive"
            continue
            ;;
    esac

    # "hostname-2026-09-05_14-30-00" -> "2026-09-05"
    stamp=${archive#"${COMPUTER}-"}
    day=${stamp%%_*}

    f_unix=$("$DATE_BIN" -d "$day" +%s)
    f_dow=$("$DATE_BIN" -d "$day" +%w)
    f_dom=$("$DATE_BIN" -d "$day" +%-d)   # %-d : sans zéro de tête, pas d'octal

    age=$((NOW_UNIX - f_unix))

    # Fils : tout ce qui est récent.
    if [ "$age" -lt "$DAILY_SEC" ]; then
        say "Quotidien (0 a $DAILY j), conservée: $archive"
        continue
    fi

    # Père : le bon jour de semaine, dans la fenêtre hebdomadaire, qui prend
    # le relais du quotidien et ne le recouvre pas.
    if [ "$f_dow" -eq "$DOW" ] && [ "$age" -lt "$WEEKLY_SEC" ]; then
        say "Hebdo ($DAILY a $((WEEKLY_SEC / 86400)) j) DOW=$f_dow, conservée: $archive"
        continue
    fi

    # Grand-père : le bon jour du mois, dans la fenêtre mensuelle, qui prend
    # à son tour le relais de l'hebdomadaire.
    if [ "$f_dom" -eq "$DOM" ] && [ "$f_unix" -gt "$MONTHLY_UNIX" ]; then
        say "Mensuel (au-dela de $((WEEKLY_SEC / 86400)) j) DOM=$f_dom, conservée: $archive"
        continue
    fi

    set -- "$@" -f "$archive"
done

# Deux paramètres par archive (-f et le nom).
COUNT=$(($# / 2))

if [ "$COUNT" -eq 0 ]; then
    say "Rien à purger."
    exit 0
fi

say "$COUNT archive(s) à supprimer."

if [ "$DRY" -eq 1 ]; then
    printf 'Dry-run, commande qui serait exécutée:\n'
    printf '%s %s %s -d %s\n' \
        "$TARSNAP_BIN" "$TARSNAP_KEYOPT" "$TARSNAP_MSGOPT" "$*"
    exit 0
fi

# Un seul appel : le man autorise -f répété en mode -d, et tarsnap met en
# cache les métadonnées, ce qui accélère nettement une purge groupée.
# shellcheck disable=SC2086
"$TARSNAP_BIN" $TARSNAP_KEYOPT $TARSNAP_MSGOPT -d "$@"

say "Terminé."
exit 0
