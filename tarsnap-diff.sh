#!/bin/sh
#
# tarsnap-diff.sh
#
# Diff entre un snapshot Tarsnap et l'état actuel du système, restreint aux
# répertoires couverts par BACKUP_DIRS dans tarsnap-backup.sh.
#
# Quatre catégories, notation calquée sur diff(1) :
#   <  supprimés   présents dans le snapshot, absents du système
#   >  nouveaux    présents sur le système, absents du snapshot
#   =  identiques  présents des deux côtés, contenu jugé identique
#   *  modifiés    présents des deux côtés, contenu jugé différent
#
# Sans option, les quatre catégories sont retenues. -d, -n, -i et -m les
# sélectionnent et se cumulent : -dn ne garde que supprimés et nouveaux.
#
# Ce choix a un effet de bord voulu sur le coût : la seule dépense réseau du
# script, hors listing, sert à départager "identique" de "modifié". Si vous
# n'avez demandé ni -i ni -m, elle est court-circuitée et l'exécution
# devient purement locale une fois le listing obtenu. Les compteurs = et *
# retombent alors sur les seules métadonnées et sont annoncés comme
# indicatifs, à l'écran comme dans le journal ; < et >, eux, restent exacts,
# ne dépendant d'aucun rapatriement.
#
# Le détail part dans un fichier journal, pas à l'écran : sur une machine
# réelle il y a des dizaines de milliers de lignes, et le tampon d'un
# terminal n'est pas un outil d'analyse. Les lignes de détail sont écrites
# au fil de l'eau sur un descripteur gardé ouvert, vous pouvez donc suivre
# la construction du diff depuis un autre terminal pendant que le script
# tourne :
#
#     tail -f /var/log/tarsnap-diff.sh-<snapshot>.log
#
# L'en-tête, qui porte les quatre compteurs, n'est ajouté qu'à la toute fin,
# en tête de fichier, parce que les compteurs ne sont évidemment connus
# qu'une fois tout classé. Le journal terminé se lit donc d'un simple :
#
#     head -15 /var/log/tarsnap-diff.sh-<snapshot>.log
#
# Ce préfixage se fait par réécriture dans un fichier voisin puis
# renommage : l'opération est atomique, mais elle change d'inode, donc un
# "tail -f" lancé pendant l'exécution suit l'ancien fichier et devra être
# relancé pour voir l'en-tête.
#
# Le journal est en texte nu, sans séquence ANSI : c'est un fichier destiné
# à être grepé ("grep '^\*'"), pas une sortie de terminal.
#
# Seuls le résumé chiffré et le chemin du journal sont imprimés sur la
# sortie standard, à la fin.
#
###############################################################################
# COMMENT LE VERDICT EST RENDU
###############################################################################
#
# Le listing de l'archive donne, pour chaque entrée, son type, sa taille et
# sa date de modification. Rien d'autre, et surtout aucune somme de
# contrôle : comparer deux contenus impose donc de rapatrier celui du
# snapshot, ce qui coûte du temps et de la bande passante facturée. D'où
# trois cas, dont un seul touche au réseau.
#
#   Tailles différentes
#       Le contenu diffère forcément : "modifié", sans rien télécharger.
#       C'est de loin le cas le plus fréquent, et il est gratuit.
#
#   Tailles égales, mtime égal
#       "identique". C'est une heuristique, assumée comme telle : un fichier
#       réécrit avec exactement la même taille, puis dont le mtime serait
#       remis à sa valeur d'origine, passerait au travers. Il faut le faire
#       exprès. Le mode strict est là pour ceux que ça ne satisfait pas.
#
#   Tailles égales, mtime différent
#       Ambigu, et seul cas qui justifie une lecture réelle. Le fichier est
#       rapatrié depuis le snapshot puis comparé octet à octet. Ça élimine
#       le faux "modifié" du fichier simplement touché par un touch, un
#       chmod mal réveillé ou une restauration.
#
# Mode strict (-S) : TOUS les fichiers réguliers communs sont rapatriés et
# comparés octet à octet, y compris ceux dont les métadonnées concordent.
# C'est la seule garantie absolue, mais ça télécharge l'intégralité de la
# partie commune du snapshot. À réserver à une vérification ponctuelle, et
# certainement pas à un cron. Sans -i ni -m il n'a rien à renforcer : il est
# alors inerte, et le script vous le dit plutôt que de l'ignorer en silence.
#
# Dans les deux modes, les fichiers à rapatrier sont d'abord rassemblés,
# puis extraits en UNE SEULE invocation de tarsnap, via l'option -T qui lit
# la liste des noms dans un fichier. Une invocation par fichier rouvrirait
# l'archive côté serveur à chaque fois, ce qui devient ruineux dès la
# centaine de fichiers.
#
# Répertoires et liens symboliques : seule leur PRÉSENCE est comparée. S'ils
# existent des deux côtés ils sont comptés "identiques", le listing ne
# donnant pas de quoi juger un changement de cible de lien ou de permissions
# de répertoire de façon fiable. Périphériques, sockets et tubes nommés sont
# ignorés : ils n'ont rien à faire dans BACKUP_DIRS.
#
###############################################################################
#
# BACKUP_DIRS, BACKUP_EXCLUDE et TARSNAP_KEY sont lus dans tarsnap-backup.sh,
# qui n'est JAMAIS sourcé, seulement lu par sed : le sourcer déclencherait
# son analyse d'options, sa prise de verrou et au bout du compte une vraie
# sauvegarde. Même précaution et même ordre de recherche que
# rotation-check.sh.
#
# BACKUP_EXCLUDE se surcharge avec -e. C'est utile parce que les exclusions
# en vigueur au moment du snapshot ne sont pas reconstituables : le script
# applique forcément celles d'aujourd'hui, et si elles ont changé depuis, -e
# vous permet de rejouer les anciennes.
#
# Aucune archive n'est touchée : seuls -tv et -x sont employés, tous deux en
# lecture seule côté Tarsnap. Le manuel est explicite, "Extracting or listing
# archives may be performed in parallel with any other operation", donc pas
# de verrou flock ici, contrairement à tarsnap-backup.sh.

# -e : on sort à la première erreur
# -u : une variable non définie est une erreur
# -f : pas de glob sur les expansions non quotées (BACKUP_DIRS, motifs
#      d'exclusion)
set -euf

#################
# CONFIGURATION #
#################

# --- Chemins absolus des binaires ---
#
# En dur pour ne pas dépendre du $PATH de l'appelant, comme dans le reste de
# la suite. Valeurs données pour Debian avec usrmerge, donc tout sous
# /usr/bin.
TARSNAP_BIN="/usr/bin/tarsnap"
FIND_BIN="/usr/bin/find"
SORT_BIN="/usr/bin/sort"
JOIN_BIN="/usr/bin/join"
CMP_BIN="/usr/bin/cmp"
SED_BIN="/usr/bin/sed"
GREP_BIN="/usr/bin/grep"
DATE_BIN="/usr/bin/date"
MKTEMP_BIN="/usr/bin/mktemp"
MKDIR_BIN="/usr/bin/mkdir"
RM_BIN="/usr/bin/rm"
MV_BIN="/usr/bin/mv"
CAT_BIN="/usr/bin/cat"
SLEEP_BIN="/usr/bin/sleep"

# stdbuf n'est PAS obligatoire : sans lui la roue de progression perd son
# compteur vivant et retombe sur une simple roue qui tourne. Outil GNU,
# absent des BSD et de macOS, d'où un test d'existence plus bas plutôt
# qu'une entrée dans la liste des binaires exigés.
STDBUF_BIN="/usr/bin/stdbuf"

# --- Journal ---
#
# Répertoire d'accueil du journal. Ne le placez pas dans un répertoire
# couvert par BACKUP_DIRS : le journal ressortirait dans son propre diff, en
# nouveau fichier. Le script vous prévient si ça arrive.
LOG_DIR="/var/log"

# --- Emplacement de tarsnap-backup.sh ---
#
# Ordre de recherche : le chemin installé ci-dessous, puis à défaut un
# tarsnap-backup.sh voisin dans le répertoire de ce script, ce qui couvre le
# cas du dépôt fraîchement cloné. L'option -f court-circuite les deux.
BACKUP_SCRIPT_INSTALLED="/usr/local/sbin/tarsnap-backup.sh"

###############################################################################
# FIN DE LA CONFIGURATION
###############################################################################

BACKUP_SCRIPT=""
SHOW_DELETED=0
SHOW_NEW=0
SHOW_IDENTICAL=0
SHOW_MODIFIED=0
ANY_CATEGORY=0
STRICT=0
VERBOSE=0
DEBUG=0
OPT_EXCLUDE=""
OPT_LOGFILE=""

# Seul endroit où un binaire est appelé sans son chemin absolu : usage() peut
# être atteinte par --help AVANT la boucle de garde-fous, et un "$CAT_BIN"
# erroné y ferait échouer l'aide au lieu de l'afficher. C'est aussi
# exactement l'idiome employé par tarsnap-backup.sh et rotation-check.sh.
usage() {
    cat >&2 <<EOF
usage: ${0##*/} [-d] [-n] [-i] [-m] [-S] [-v] [-e "motifs"]
                [-l journal] [-f script] [--debug] SNAPSHOT

  -d, --deleted         retient les fichiers supprimés depuis le snapshot
  -n, --new             retient les nouveaux fichiers, absents du snapshot
  -i, --identical       retient les fichiers identiques
  -m, --modified        retient les fichiers modifiés
                        Sans aucune de ces quatre options, tout est retenu.
  -S, --strict          vérification stricte : rapatrie et compare octet à
                        octet TOUS les fichiers communs, et pas seulement
                        ceux dont les métadonnées divergent. Long, et
                        facturé par Tarsnap au volume transféré. Sans effet
                        si ni -i ni -m n'est demandé, le script le signale.
  -v, --verbose         détaille la progression sur la sortie d'erreur
  -e, --exclude MOTIFS  surcharge BACKUP_EXCLUDE, motifs entre guillemets
                        et séparés par des espaces
  -l, --log FICHIER     chemin du journal
                        (défaut : $LOG_DIR/${0##*/}-SNAPSHOT.log)
  -f, --file SCRIPT     chemin de tarsnap-backup.sh, d'où sont lus
                        BACKUP_DIRS, BACKUP_EXCLUDE et TARSNAP_KEY
      --debug           trace d'exécution (set -x), et conservation du
                        répertoire temporaire dont le chemin est affiché
  -h, --help            affiche cette aide

SNAPSHOT est le nom exact d'une archive existante, que liste
"tarsnap --list-archives".
EOF
    exit "${1:-1}"
}

die() {
    printf 'ERREUR: %s\n' "$*" >&2
    exit 1
}

# Progression, sur la sortie d'erreur pour laisser la sortie standard au
# seul résumé. Le "return 0" est indispensable : sans lui, un [ ] faux
# ferait sortir le script à cause de set -e. Même motif que le say() de
# tarsnap-backup.sh.
say() {
    [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$*" >&2
    return 0
}

dbg() {
    [ "$DEBUG" -eq 1 ] && printf 'DEBUG: %s\n' "$*" >&2
    return 0
}

# --- Traduction des formes longues ---
#
# getopts POSIX ne connaît que les options d'un caractère : on réécrit les
# formes longues en formes courtes avant de le lancer, en acceptant un ou
# deux tirets. Même mécanique que tarsnap-backup.sh.
#
# --debug devient -X, une lettre volontairement absente de la forme courte
# documentée : c'est une option de mise au point, pas une option d'usage.
for arg do
    shift
    case "$arg" in
        --help|-help)           usage 0 ;;
        --deleted|-deleted)     set -- "$@" -d ;;
        --new|-new)             set -- "$@" -n ;;
        --identical|-identical) set -- "$@" -i ;;
        --modified|-modified)   set -- "$@" -m ;;
        --strict|-strict)       set -- "$@" -S ;;
        --verbose|-verbose)     set -- "$@" -v ;;
        --debug|-debug)         set -- "$@" -X ;;
        # Forme accolée : on découpe nous-mêmes sur le premier "=".
        --exclude=*|-exclude=*) set -- "$@" -e "${arg#*=}" ;;
        --log=*|-log=*)         set -- "$@" -l "${arg#*=}" ;;
        --file=*|-file=*)       set -- "$@" -f "${arg#*=}" ;;
        # Forme séparée : on émet juste la lettre, la valeur suit dans $@ et
        # c'est getopts qui la ramassera, y compris pour râler si elle manque.
        --exclude|-exclude)     set -- "$@" -e ;;
        --log|-log)             set -- "$@" -l ;;
        --file|-file)           set -- "$@" -f ;;
        *)                      set -- "$@" "$arg" ;;
    esac
done

while getopts "dnimSvXe:l:f:h" option; do
    case "$option" in
        d) SHOW_DELETED=1;   ANY_CATEGORY=1 ;;
        n) SHOW_NEW=1;       ANY_CATEGORY=1 ;;
        i) SHOW_IDENTICAL=1; ANY_CATEGORY=1 ;;
        m) SHOW_MODIFIED=1;  ANY_CATEGORY=1 ;;
        S) STRICT=1 ;;
        v) VERBOSE=1 ;;
        X) DEBUG=1; VERBOSE=1 ;;
        e) OPT_EXCLUDE=$OPTARG ;;
        l) OPT_LOGFILE=$OPTARG ;;
        f) BACKUP_SCRIPT=$OPTARG ;;
        h) usage 0 ;;
        *) usage 1 ;;
    esac
done
shift $((OPTIND - 1))

if [ "$DEBUG" -eq 1 ]; then
    set -x
fi

if [ "$ANY_CATEGORY" -eq 0 ]; then
    SHOW_DELETED=1; SHOW_NEW=1; SHOW_IDENTICAL=1; SHOW_MODIFIED=1
fi

# La vérification octet à octet n'existe que pour départager "identique" de
# "modifié". Si vous n'avez demandé ni l'un ni l'autre, elle ne tranche rien
# que vous vouliez savoir : autant ne pas payer le rapatriement. C'est le
# seul poste de dépense réseau du script, donc "tarsnap-diff.sh -d" devient
# purement local une fois le listing obtenu.
#
# Les autres étapes, elles, ne sont PAS économisables : "supprimé" et
# "nouveau" se déduisent du rapprochement des deux inventaires complets, il
# faut donc lister l'archive ET parcourir le système dans tous les cas.
NEED_BYTE_CHECK=0
if [ "$SHOW_IDENTICAL" -eq 1 ] || [ "$SHOW_MODIFIED" -eq 1 ]; then
    NEED_BYTE_CHECK=1
fi

[ $# -eq 1 ] || usage 1
SNAPSHOT_NAME=$1

# Le nom de snapshot finit dans un nom de fichier journal et sur une ligne
# de commande : on refuse tout ce qui introduirait un espace ou un caractère
# exotique. Liste explicite plutôt qu'un intervalle [A-Za-z], dont le
# contenu dépend de la locale. Le point est admis, pour les archives .part.
case "$SNAPSHOT_NAME" in
    "") die "nom de snapshot vide" ;;
    *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-]*)
        die "nom de snapshot invalide, caractères autorisés: A-Z a-z 0-9 _ - ." ;;
esac

###############################################################################
# LECTURE DE LA CONFIGURATION DE tarsnap-backup.sh
###############################################################################

if [ -z "$BACKUP_SCRIPT" ]; then
    # ${0%/*} rend le répertoire, sauf si $0 ne contient aucun slash, auquel
    # cas il rend $0 lui-même : d'où le case plutôt qu'un dirname.
    case "$0" in
        */*) HERE=${0%/*} ;;
        *)   HERE="." ;;
    esac
    if [ -r "$BACKUP_SCRIPT_INSTALLED" ]; then
        BACKUP_SCRIPT=$BACKUP_SCRIPT_INSTALLED
    elif [ -r "$HERE/tarsnap-backup.sh" ]; then
        BACKUP_SCRIPT="$HERE/tarsnap-backup.sh"
    else
        die "tarsnap-backup.sh introuvable dans $BACKUP_SCRIPT_INSTALLED ni dans $HERE, utilisez -f"
    fi
fi
[ -r "$BACKUP_SCRIPT" ] || die "illisible: $BACKUP_SCRIPT"

# Lecture d'une valeur NOM="..." dans le script de sauvegarde.
#
# Contrairement au read_value de rotation-check.sh, qui lit des entiers
# jamais vides, une valeur vide est ici parfaitement légitime :
# TARSNAP_KEY="" est le cas documenté "je m'en remets au tarsnap.conf". D'où
# le grep préalable, qui distingue "déclarée et vide" de "pas déclarée du
# tout", là où un sed muet confondrait les deux.
read_string() {
    _name=$1
    "$GREP_BIN" -q "^${_name}=\"" "$BACKUP_SCRIPT" \
        || die "variable $_name introuvable dans $BACKUP_SCRIPT"
    "$SED_BIN" -n "/^${_name}=/{s/^${_name}=\"\(.*\)\".*/\1/p;q;}" "$BACKUP_SCRIPT"
}

TARSNAP_KEY=$(read_string TARSNAP_KEY)
BACKUP_DIRS=$(read_string BACKUP_DIRS)
BACKUP_EXCLUDE=$(read_string BACKUP_EXCLUDE)

if [ -n "$OPT_EXCLUDE" ]; then
    BACKUP_EXCLUDE=$OPT_EXCLUDE
    say "BACKUP_EXCLUDE surchargé : $BACKUP_EXCLUDE"
fi

dbg "BACKUP_SCRIPT=$BACKUP_SCRIPT"
dbg "BACKUP_DIRS=$BACKUP_DIRS"
dbg "BACKUP_EXCLUDE=$BACKUP_EXCLUDE"

###############################################################################
# GARDE-FOUS
###############################################################################

for bin in "$TARSNAP_BIN" "$FIND_BIN" "$SORT_BIN" "$JOIN_BIN" "$CMP_BIN" \
           "$SED_BIN" "$GREP_BIN" "$DATE_BIN" "$MKTEMP_BIN" "$MKDIR_BIN" \
           "$RM_BIN" "$MV_BIN" "$CAT_BIN" "$SLEEP_BIN"; do
    [ -x "$bin" ] || die "binaire absent ou non exécutable: $bin"
done

[ -n "$BACKUP_DIRS" ] || die "BACKUP_DIRS est vide dans $BACKUP_SCRIPT"

# -S ne fait que renforcer la distinction identique/modifié : sans -i ni -m,
# il n'a rien à renforcer. On le dit plutôt que de l'ignorer en silence.
if [ "$STRICT" -eq 1 ] && [ "$NEED_BYTE_CHECK" -eq 0 ]; then
    printf 'ATTENTION: -S est sans effet ici, ni -i ni -m n etant demande.\n' >&2
fi

if [ -n "$TARSNAP_KEY" ] && [ ! -r "$TARSNAP_KEY" ]; then
    die "clé tarsnap illisible: $TARSNAP_KEY"
fi

# Options communes aux invocations de tarsnap. Volontairement laissées non
# quotées à l'usage : elles doivent disparaître de la ligne de commande
# quand elles sont vides. Même convention que tarsnap-backup.sh.
if [ -n "$TARSNAP_KEY" ]; then
    TARSNAP_KEYOPT="--keyfile $TARSNAP_KEY"
else
    TARSNAP_KEYOPT=""
fi

# --- Ouverture du journal ---
if [ -n "$OPT_LOGFILE" ]; then
    LOGFILE=$OPT_LOGFILE
else
    LOGFILE="${LOG_DIR}/${0##*/}-${SNAPSHOT_NAME}.log"
fi
case "$LOGFILE" in
    */*) LOGDIR_EFF=${LOGFILE%/*} ;;
    *)   LOGDIR_EFF="." ;;
esac
[ -d "$LOGDIR_EFF" ] || die "répertoire de journal inexistant: $LOGDIR_EFF"
: > "$LOGFILE" || die "journal non inscriptible: $LOGFILE"

# Fichier de travail du préfixage final, voisin du journal pour que le
# renommage reste dans le même système de fichiers, donc atomique. Déclaré
# ici parce que cleanup() doit pouvoir le retirer, et que set -u tuerait le
# script sur une variable encore indéfinie au moment d'un signal.
LOGFILE_TMP="${LOGFILE}.$$.tmp"

# Horodatage pris au DÉBUT et conservé : l'en-tête n'est écrit qu'à la fin,
# mais c'est bien l'heure de lancement qui vous intéresse, pas celle où le
# script a fini de recopier.
STARTED_AT=$("$DATE_BIN" '+%Y-%m-%d %H:%M:%S')

# Le journal ne doit pas atterrir dans l'arborescence comparée, sinon il
# ressort dans son propre diff. Non bloquant, c'est cosmétique : on
# prévient, et on continue.
for _d in $BACKUP_DIRS; do
    case "$LOGFILE" in
        "$_d"/*)
            printf 'ATTENTION: le journal %s est sous %s, couvert par BACKUP_DIRS.\n' \
                "$LOGFILE" "$_d" >&2
            printf '           il apparaitra dans son propre diff, en nouveau fichier.\n' >&2
            ;;
    esac
done

###############################################################################
# TEMPORAIRES, ROUE DE PROGRESSION ET NETTOYAGE
###############################################################################

TMP_DIR=""
SPINNER_PID=""

# Nettoyage idempotent : les gestionnaires INT et TERM y repassent via le
# trap EXIT, ce qui est sans effet.
#
# SC2317 est neutralisé ici : shellcheck ne suit pas les appels faits depuis
# un trap et croit donc tout le corps mort. Il ne l'est pas.
# shellcheck disable=SC2317
cleanup() {
    if [ -n "$SPINNER_PID" ]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
        # Effacement par un champ de largeur fixe : aucune séquence ANSI,
        # donc ça se tient aussi sur un terminal stupide.
        printf '\r%78s\r' '' >&2
    fi
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        if [ "$DEBUG" -eq 1 ]; then
            printf 'DEBUG: repertoire temporaire conserve: %s\n' "$TMP_DIR" >&2
        else
            "$RM_BIN" -rf "$TMP_DIR"
        fi
    fi
    # Le fichier de travail du préfixage n'a de sens qu'entre sa création et
    # le renommage, qui remet la variable à vide. S'il traîne encore ici,
    # c'est qu'on est sorti au milieu : il ne doit pas survivre à côté du
    # journal, où il ressemblerait à un second journal tronqué.
    if [ -n "$LOGFILE_TMP" ] && [ -f "$LOGFILE_TMP" ]; then
        "$RM_BIN" -f "$LOGFILE_TMP"
    fi
    return 0
}

# Les gestionnaires de signaux SORTENT après avoir nettoyé, et c'est tout
# l'intérêt de les séparer du trap EXIT. Un simple "trap cleanup INT"
# nettoierait puis laisserait le script continuer sur un répertoire
# temporaire qui vient d'être effacé, et la suite déraillerait en cascade
# sur des "Directory nonexistent". Codes de sortie 128 + numéro du signal,
# comme le fait un shell.
trap 'cleanup' EXIT
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# mktemp sans template crée $TMPDIR/tmp.XXXXXXXXXX, soit /tmp/tmp.XXXXXXXXXX
# quand TMPDIR est vide : un nom qui ne dit rien à personne quand on le
# retrouve dans un message d'erreur. Avec template, il s'annonce.
TMP_DIR=$("$MKTEMP_BIN" -d "${TMPDIR:-/tmp}/tarsnap-diff.XXXXXXXX") \
    || die "impossible de créer le répertoire temporaire dans ${TMPDIR:-/tmp}"
dbg "TMP_DIR=$TMP_DIR"

ARCHIVE_RAW="$TMP_DIR/archive.raw"
ARCHIVE_META="$TMP_DIR/archive.meta"
LOCAL_RAW="$TMP_DIR/local.raw"
LOCAL_META="$TMP_DIR/local.meta"
DELETED_LIST="$TMP_DIR/deleted"
NEW_LIST="$TMP_DIR/new"
COMMON_LIST="$TMP_DIR/common"
CANDIDATES="$TMP_DIR/candidates"
VERDICTS="$TMP_DIR/verdicts"
EXTRACT_DIR="$TMP_DIR/extract"
TARSNAP_ERR="$TMP_DIR/tarsnap.err"

TAB=$(printf '\t')

# Roue de progression, reprise de tarsnap-stats.sh. Deux modes : "count"
# affiche le nombre de lignes déjà reçues dans le fichier surveillé,
# "plain" se contente de tourner. Rien n'est dessiné tant que le fichier
# surveillé est vide : pendant cette fenêtre tarsnap peut encore réclamer la
# phrase de passe de la clé, et la ligne de progression ne doit surtout pas
# se poser dessus.
#
# $1 libellé, $2 "count" ou "plain", $3 fichier à compter en mode count.
spin_start() {
    [ "${TARSNAP_SPINNER:-1}" = 1 ] || return 0
    [ -t 2 ] || return 0
    # La roue et set -x ne cohabitent pas : la trace du sous-shell noierait
    # le terminal.
    [ "$DEBUG" -eq 1 ] && return 0
    _label=$1
    _mode=$2
    _watch=${3:-}
    {
        while :; do
            for frame in '|' '/' '-' "\\"; do
                if [ "$_mode" = count ] && [ -s "$_watch" ]; then
                    _n=$("$GREP_BIN" -c . "$_watch" 2>/dev/null || echo 0)
                    printf '\r%s %.55s : %d entrees' "$frame" "$_label" "$_n" >&2
                else
                    printf '\r%s %.70s' "$frame" "$_label" >&2
                fi
                # sleep fractionnaire : pas POSIX, mais accepté par tous les
                # sleep(1) qui comptent ici (GNU, FreeBSD, macOS, busybox).
                "$SLEEP_BIN" 0.2
            done
        done
    } &
    SPINNER_PID=$!
    return 0
}

spin_stop() {
    [ -n "$SPINNER_PID" ] || return 0
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
    printf '\r%78s\r' '' >&2
    return 0
}

# stdbuf force tarsnap à vider sa sortie ligne à ligne au lieu de remplir
# d'abord un tampon stdio de 4 ko : sans lui, le compteur de la roue
# sauterait de zéro au total d'un seul coup. Outil GNU, absent des BSD et de
# macOS, d'où le repli sur la roue simple.
if [ -x "$STDBUF_BIN" ]; then
    SPIN_MODE=count
else
    SPIN_MODE=plain
fi

###############################################################################
# ÉTAPE 1 : LISTING DE L'ARCHIVE
###############################################################################

say "Listing de l'archive ${SNAPSHOT_NAME}."
: > "$ARCHIVE_RAW"
rc=0
spin_start "listing de $SNAPSHOT_NAME" "$SPIN_MODE" "$ARCHIVE_RAW"
# shellcheck disable=SC2086
if [ "$SPIN_MODE" = count ]; then
    "$STDBUF_BIN" -oL "$TARSNAP_BIN" $TARSNAP_KEYOPT -tv --iso-dates \
        -f "$SNAPSHOT_NAME" > "$ARCHIVE_RAW" || rc=$?
else
    # shellcheck disable=SC2086
    "$TARSNAP_BIN" $TARSNAP_KEYOPT -tv --iso-dates \
        -f "$SNAPSHOT_NAME" > "$ARCHIVE_RAW" || rc=$?
fi
spin_stop
if [ "$rc" -ne 0 ]; then
    die "\"tarsnap -tv -f $SNAPSHOT_NAME\" a échoué (code $rc), voir son message ci-dessus"
fi

###############################################################################
# ÉTAPE 2 : NORMALISATION DES DEUX INVENTAIRES
###############################################################################
#
# Les deux côtés produisent le même format à quatre champs séparés par des
# tabulations : chemin relatif, type, taille, date de modification.
#
# La date reste une CHAÎNE "AAAA-MM-JJ HH:MM:SS" et n'est jamais convertie
# en epoch. C'est le point de performance du script. "tarsnap -tv
# --iso-dates" et "find -printf '%TY-%Tm-%Td %TH:%TM:%TS'" rendent tous deux
# l'heure locale dans ce format, au champ des secondes fractionnaires près
# que find ajoute et qu'on tronque au point. Comparer les chaînes donne donc
# exactement le même verdict que comparer des epochs, sans appeler date.
#
# La version précédente forkait un "date -d" par entrée d'archive. Mesuré :
# 0,74 ms par fork sur x86, plusieurs fois plus sur un ARM. Sur les 50 000
# entrées d'une machine réelle, ça faisait passer cette étape de quelques
# secondes à plusieurs minutes de fork pur, pour un résultat identique.

# Un motif par élément de BACKUP_EXCLUDE, même logique que tarsnap-backup.sh.
# Chemin absolu : ancré, sur le chemin lui-même comme sur tout ce qu'il
# contient. Motif globbé : passé tel quel à un case.
is_excluded() {
    _path=$1
    for _pat in $BACKUP_EXCLUDE; do
        case "$_pat" in
            /*)
                _rel=${_pat#/}
                case "$_path" in
                    "$_rel"|"$_rel"/*) return 0 ;;
                esac
                ;;
            *)
                # shellcheck disable=SC2254
                case "$_path" in
                    $_pat) return 0 ;;
                esac
                ;;
        esac
    done
    return 1
}

say "Normalisation du listing d'archive."
# La redirection porte sur le BLOC, pas sur chaque printf : un ">>" par
# ligne rouvrirait le fichier à chacune des 50 000 entrées.
{
    while read -r perm _links _owner _group size fdate ftime rest; do
        [ -n "${rest:-}" ] || continue
        # Premier caractère du champ des permissions, sans forker cut(1) :
        # on retire tout sauf le premier caractère par expansion.
        type=${perm%"${perm#?}"}
        case "$type" in
            -|d|l) ;;
            *) continue ;;   # périphériques, sockets, tubes : hors sujet
        esac
        name=$rest
        # Le listing suffixe la cible d'un lien : " -> cible" pour un lien
        # symbolique, " link to cible" pour un lien physique. On ne garde
        # que le nom de l'entrée elle-même.
        case "$type" in
            l) name=${name%% -> *} ;;
        esac
        name=${name%% link to *}
        # Le listing suffixe aussi les répertoires d'un "/", find non : on
        # aligne les deux clés.
        name=${name%/}
        is_excluded "$name" && continue
        printf '%s\t%s\t%s\t%s %s\n' "$name" "$type" "$size" "$fdate" "$ftime"
    done < "$ARCHIVE_RAW"
} > "$ARCHIVE_META"

###############################################################################
# ÉTAPE 3 : ÉTAT ACTUEL DU SYSTÈME DE FICHIERS
###############################################################################

say "Parcours du système de fichiers."
: > "$LOCAL_RAW"
for dir in $BACKUP_DIRS; do
    if [ ! -e "$dir" ]; then
        printf 'ATTENTION: repertoire de BACKUP_DIRS absent, ignore: %s\n' "$dir" >&2
        continue
    fi
    "$FIND_BIN" "$dir" \
        -printf '%y\t%s\t%TY-%Tm-%Td %TH:%TM:%TS\t%p\n' >> "$LOCAL_RAW"
done

{
    # IFS forcé à la tabulation, et pas l'IFS par défaut : le champ de date
    # contient un espace entre le jour et l'heure, que le découpage par
    # défaut prendrait pour un séparateur de champ. Corollaire, un nom de
    # fichier contenant une tabulation casserait ce format ; il casserait de
    # toute façon aussi join, qui travaille sur les mêmes colonnes.
    while IFS="$TAB" read -r ftype fsize fstamp fpath; do
        [ -n "${fpath:-}" ] || continue
        case "$ftype" in
            f) type=- ;;
            d) type=d ;;
            l) type=l ;;
            *) continue ;;
        esac
        # tarsnap retire le "/" de tête des noms d'entrée, sauf avec -P : les
        # deux inventaires doivent porter la même clé, on l'enlève donc aussi
        # de ce côté.
        name=${fpath#/}
        is_excluded "$name" && continue
        # find rend les secondes avec leur partie fractionnaire
        # ("22:43:01.7108968160"), que tarsnap n'imprime pas : on tronque au
        # point.
        printf '%s\t%s\t%s\t%s\n' "$name" "$type" "$fsize" "${fstamp%%.*}"
    done < "$LOCAL_RAW"
} > "$LOCAL_META"

###############################################################################
# ÉTAPE 4 : RAPPROCHEMENT DES DEUX INVENTAIRES
###############################################################################
#
# LC_ALL=C sur sort ET sur join : join travaille mal, en silence, si l'ordre
# de collationnement de ses entrées n'est pas celui qu'il emploie lui-même.
#
# Le "-u" porte sur la clé seule et se prémunit d'un doublon de chemin :
# deux entrées de BACKUP_DIRS qui se recouvrent côté système, ou une archive
# contenant deux fois le même chemin, ce que tarsnap autorise. Sans lui,
# join produirait le produit cartésien des doublons.

say "Rapprochement des deux inventaires."
LC_ALL=C "$SORT_BIN" -t "$TAB" -k1,1 -u "$ARCHIVE_META" -o "$ARCHIVE_META"
LC_ALL=C "$SORT_BIN" -t "$TAB" -k1,1 -u "$LOCAL_META"   -o "$LOCAL_META"

# join joint par défaut sur le premier champ de chaque fichier, ce qui est
# exactement notre cas : inutile de préciser -1 et -2.
LC_ALL=C "$JOIN_BIN" -t "$TAB" -v 1 "$ARCHIVE_META" "$LOCAL_META" > "$DELETED_LIST"
LC_ALL=C "$JOIN_BIN" -t "$TAB" -v 2 "$ARCHIVE_META" "$LOCAL_META" > "$NEW_LIST"
LC_ALL=C "$JOIN_BIN" -t "$TAB"      "$ARCHIVE_META" "$LOCAL_META" > "$COMMON_LIST"

###############################################################################
# ÉTAPE 5 : JOURNAL
###############################################################################

# Le journal est ouvert une fois pour toutes sur le descripteur 3, et gardé
# ouvert jusqu'à la fin. Chaque ligne y arrive donc immédiatement, sans
# tampon intermédiaire, et un "tail -f" depuis un autre terminal voit le
# diff se construire au lieu d'attendre que le script rende la main.
#
# Seules les lignes de détail y passent. L'en-tête, qui porte les quatre
# compteurs, leur est préfixé à l'étape 6, une fois ceux-ci connus.
exec 3>>"$LOGFILE" || die "journal non inscriptible: $LOGFILE"

log() {
    printf '%s\n' "$*" >&3
}

del_count=0
new_count=0
id_count=0
mod_count=0
cand_count=0

# Supprimés et nouveaux : verdict immédiat, aucun accès réseau. Ils partent
# dans le journal tout de suite, avant la phase lente, pour qu'un "tail -f"
# ait de quoi lire dès les premières secondes.
while IFS="$TAB" read -r path _type _size _stamp; do
    [ -n "$path" ] || continue
    del_count=$((del_count + 1))
    [ "$SHOW_DELETED" -eq 1 ] && log "< ${path}"
done < "$DELETED_LIST"

while IFS="$TAB" read -r path _type _size _stamp; do
    [ -n "$path" ] || continue
    new_count=$((new_count + 1))
    [ "$SHOW_NEW" -eq 1 ] && log "> ${path}"
done < "$NEW_LIST"

say "$del_count supprimé(s), $new_count nouveau(x)."

###############################################################################
# ÉTAPE 5b : TRI DES FICHIERS COMMUNS
###############################################################################
#
# Premier passage, entièrement local : on tranche tout ce qui peut l'être
# sans réseau, et on met de côté les seuls cas réellement ambigus. Les
# verdicts sûrs sont journalisés au fil de l'eau.
#
# La redirection porte sur le bloc, ce qui ne crée PAS de sous-shell en sh
# POSIX, contrairement à un pipeline : les compteurs incrémentés ici
# survivent bien à la fermeture du bloc. Vérifié sous dash et sous bash.

say "Classement des fichiers communs."
{
    while IFS="$TAB" read -r path type_a size_a stamp_a _type_l size_l stamp_l; do
        [ -n "$path" ] || continue

        # Répertoires et liens : leur seule présence des deux côtés vaut
        # identique, cf. les limites en tête de script.
        if [ "$type_a" != "-" ]; then
            id_count=$((id_count + 1))
            [ "$SHOW_IDENTICAL" -eq 1 ] && log "= ${path}"
            continue
        fi

        # Le mode strict envoie tout au rapatriement, sauf s'il n'y a de
        # toute façon rien à départager.
        if [ "$STRICT" -eq 0 ] || [ "$NEED_BYTE_CHECK" -eq 0 ]; then
            if [ "$size_a" != "$size_l" ]; then
                # Tailles différentes : le contenu diffère forcément, aucune
                # raison de payer un rapatriement pour le confirmer.
                mod_count=$((mod_count + 1))
                [ "$SHOW_MODIFIED" -eq 1 ] && log "* ${path}"
                continue
            fi
            if [ "$stamp_a" = "$stamp_l" ]; then
                # Taille et mtime concordants : identique, par heuristique.
                id_count=$((id_count + 1))
                [ "$SHOW_IDENTICAL" -eq 1 ] && log "= ${path}"
                continue
            fi
        fi

        # Reste le cas ambigu.
        if [ "$NEED_BYTE_CHECK" -eq 0 ]; then
            # Ni -i ni -m demandés : le rapatriement ne servirait qu'à
            # départager deux catégories dont vous ne voulez rien savoir. On
            # s'en tient au verdict de métadonnées, qui ne peut être que
            # "modifié" puisque le mtime diffère. Le compteur est donc
            # indicatif, et le journal le dit.
            mod_count=$((mod_count + 1))
            continue
        fi

        cand_count=$((cand_count + 1))
        printf '%s\n' "$path"
    done < "$COMMON_LIST"
} > "$CANDIDATES"

if [ "$NEED_BYTE_CHECK" -eq 0 ]; then
    say "Rapatriement court-circuite : ni -i ni -m demandes, rien a departager."
else
    say "$cand_count fichier(s) à vérifier octet à octet."
fi

###############################################################################
# ÉTAPE 5c : VÉRIFICATION OCTET À OCTET DES CAS AMBIGUS
###############################################################################

if [ "$cand_count" -gt 0 ]; then
    "$MKDIR_BIN" -p "$EXTRACT_DIR"

    # UNE seule invocation de tarsnap pour toute la liste. L'option -T lit
    # les noms dans un fichier et -C place l'extraction dans le répertoire
    # temporaire. Une invocation par fichier rouvrirait l'archive côté
    # serveur à chaque fois, ce qui rendait la version précédente
    # inutilisable dès la centaine de fichiers.
    say "Rapatriement de $cand_count fichier(s) depuis le snapshot."
    rc=0
    spin_start "rapatriement de $cand_count fichier(s)" plain
    # shellcheck disable=SC2086
    "$TARSNAP_BIN" $TARSNAP_KEYOPT -x -C "$EXTRACT_DIR" \
        -f "$SNAPSHOT_NAME" -T "$CANDIDATES" 2> "$TARSNAP_ERR" || rc=$?
    spin_stop
    if [ "$rc" -ne 0 ]; then
        printf 'ATTENTION: "tarsnap -x" a rendu %s, la comparaison octet a octet\n' "$rc" >&2
        printf '           peut donc etre incomplete. Message de tarsnap :\n' >&2
        "$SED_BIN" 's/^/  /' "$TARSNAP_ERR" >&2
    fi

    say "Comparaison octet à octet."
    {
        while read -r path; do
            [ -n "$path" ] || continue
            if [ ! -e "$EXTRACT_DIR/$path" ]; then
                # Non rapatrié : on ne peut rien affirmer, donc on se garde
                # bien de prétendre que c'est identique. Verdict prudent.
                printf 'ATTENTION: non rapatrie, verdict force a "modifie": %s\n' \
                    "$path" >&2
                printf '*\t%s\n' "$path"
                continue
            fi
            # Piège classique sous set -e : dans "if cmd; then X; fi" sans
            # else exécuté, $? après le fi vaut 0 par la spécification POSIX
            # et non le code de cmd. D'où le else explicite, seul endroit où
            # $? reflète encore fidèlement le code de retour de cmp.
            if "$CMP_BIN" -s "$EXTRACT_DIR/$path" "/$path"; then
                _rc=0
            else
                _rc=$?
            fi
            case "$_rc" in
                0) printf '=\t%s\n' "$path" ;;
                1) printf '*\t%s\n' "$path" ;;
                *) printf 'ATTENTION: cmp a rendu %s, verdict force a "modifie": %s\n' \
                       "$_rc" "$path" >&2
                   printf '*\t%s\n' "$path" ;;
            esac
        done < "$CANDIDATES"
    } > "$VERDICTS"

    while IFS="$TAB" read -r verdict path; do
        [ -n "$path" ] || continue
        case "$verdict" in
            '=') id_count=$((id_count + 1))
                 [ "$SHOW_IDENTICAL" -eq 1 ] && log "= ${path}" ;;
            '*') mod_count=$((mod_count + 1))
                 [ "$SHOW_MODIFIED" -eq 1 ] && log "* ${path}" ;;
        esac
    done < "$VERDICTS"
fi

###############################################################################
# ÉTAPE 6 : RÉSUMÉ
###############################################################################

# L'en-tête n'a pu être écrit plus tôt : il porte les quatre compteurs, qui
# ne sont connus qu'ici. On le construit donc dans un fichier voisin, on y
# recopie le détail accumulé, et on renomme par-dessus.
#
# Voisin, et pas dans TMP_DIR : rename(2) ne franchit pas les systèmes de
# fichiers, et TMP_DIR vit sous /tmp, qui est très souvent ailleurs. Le
# renommage local est atomique, le journal n'est donc jamais laissé
# tronqué, même si la machine tombe pendant l'opération.
exec 3>&-

{
    printf '# %s\n'                    "${0##*/}"
    printf '# snapshot    : %s\n'      "$SNAPSHOT_NAME"
    printf '# date        : %s\n'      "$STARTED_AT"
    printf '# repertoires : %s\n'      "$BACKUP_DIRS"
    printf '# exclusions  : %s\n'      "$BACKUP_EXCLUDE"
    if [ "$NEED_BYTE_CHECK" -eq 0 ]; then
        printf '# mode        : metadonnees seules, ni -i ni -m n ayant ete demandes\n'
        printf '#               aucun rapatriement, donc les compteurs = et * sont\n'
        printf '#               indicatifs : ils n ont pas ete verifies octet a octet\n'
    elif [ "$STRICT" -eq 1 ]; then
        printf '# mode        : strict, comparaison octet a octet de tous les communs\n'
    else
        printf '# mode        : hybride, octet a octet si taille egale et mtime different\n'
    fi
    printf '#\n'
    printf '# supprimes  (<) : %s\n'   "$del_count"
    printf '# nouveaux   (>) : %s\n'   "$new_count"
    printf '# identiques (=) : %s\n'   "$id_count"
    printf '# modifies   (*) : %s\n'   "$mod_count"
    "$CAT_BIN" "$LOGFILE"
} > "$LOGFILE_TMP" || die "écriture impossible: $LOGFILE_TMP"

"$MV_BIN" -f "$LOGFILE_TMP" "$LOGFILE" || die "renommage impossible: $LOGFILE_TMP"
LOGFILE_TMP=""

printf 'Diff de %s\n\n' "$SNAPSHOT_NAME"
printf '  supprimes   (<) : %s\n' "$del_count"
printf '  nouveaux    (>) : %s\n' "$new_count"
if [ "$NEED_BYTE_CHECK" -eq 0 ]; then
    # Sans -i ni -m, ces deux compteurs sortent des seules métadonnées : on
    # ne les présente pas comme s'ils avaient été vérifiés.
    printf '  identiques  (=) : %s  (indicatif, non verifie)\n' "$id_count"
    printf '  modifies    (*) : %s  (indicatif, non verifie)\n' "$mod_count"
else
    printf '  identiques  (=) : %s\n' "$id_count"
    printf '  modifies    (*) : %s\n' "$mod_count"
fi
printf '  --------------------------------\n'
printf '  total           : %s\n\n' \
    "$((del_count + new_count + id_count + mod_count))"
printf 'Detail : %s\n' "$LOGFILE"

exit 0
