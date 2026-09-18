#!/bin/sh
#
# rotation-check.sh
#
# Harnais de diagnostic pour tarsnap-backup.sh. Ne touche NI tarsnap, NI le réseau, NI la moindre archive : 
# il rejoue la seule logique de décision de la rotation, à la ligne près.
#
# Deux modes :
#
#   - simulation (par défaut)
#       Génère un historique d'archives quotidiennes sur N jours et compte ce que chaque palier retiendrait.  
#       Indispensable quand la machine ne tourne que depuis quelques semaines : 
#       un --dry-run réel ne prouve rien tant que toutes les archives sont dans la fenêtre quotidienne.
#
#   - rejeu (-l)
#       Rejoue la décision sur une vraie liste d'archives, lue dans un fichier ou sur l'entrée standard :
#           tarsnap --list-archives | ./rotation-check.sh -l -
#
# Les valeurs de rétention sont lues directement dans tarsnap-backup.sh
#
# Les options permettent de comparer un scénario sans rien y toucher.

set -euf

DATE_BIN="/usr/bin/date"
UNAME_BIN="/usr/bin/uname"
SED_BIN="/usr/bin/sed"

# --- Emplacement de tarsnap-backup.sh ---
# Ordre de recherche : le chemin installé ci-dessous, puis, à défaut, un tarsnap-backup.sh voisin dans le répertoire du harnais, ce qui couvre le cas du dépôt fraîchement cloné. 
# L'option -f court-circuite les deux.

BACKUP_SCRIPT_INSTALLED="/usr/local/sbin/tarsnap-backup.sh"

DAYS=1825         # horizon simulé, 5 ans
LISTFILE=""       # non vide = mode rejeu
BACKUP_SCRIPT=""  # non vide = chemin imposé par -f

# Surcharges de ligne de commande. Vide = on garde la valeur lue dans le script testé.
OPT_DAILY=""
OPT_WEEKLY=""
OPT_MONTHLY=""
OPT_DOW=""
OPT_DOM=""

usage() {
    cat >&2 <<EOF
usage: ${0##*/} [-D jours] [-f script] [-d DAILY] [-w WEEKLY] [-m MONTHLY]
                [-o DOW] [-M DOM] [-l fichier|-] [-h]

  -D jours    horizon de la simulation (defaut $DAYS)
  -f script   chemin de tarsnap-backup.sh, ou lire la configuration
  -d DAILY    surcharge la fenetre quotidienne, en jours
  -w WEEKLY   surcharge la fenetre hebdomadaire, en semaines
  -m MONTHLY  surcharge la fenetre mensuelle, en mois
  -o DOW      surcharge le jour de semaine conserve, 0=dimanche
  -M DOM      surcharge le jour du mois conserve
  -l fichier  rejeu sur une vraie liste d archives, "-" pour stdin
  -h          affiche cette aide

Sans surcharge, les cinq valeurs de retention sont lues dans tarsnap-backup.sh. 
Recherche : $BACKUP_SCRIPT_INSTALLED, puis le repertoire de ce script.
EOF
    exit "${1:-1}"
}

die() {
    printf 'ERREUR: %s\n' "$*" >&2
    exit 1
}

while getopts "D:f:d:w:m:o:M:l:h" opt; do
    case "$opt" in
        D) DAYS=$OPTARG ;;
        f) BACKUP_SCRIPT=$OPTARG ;;
        d) OPT_DAILY=$OPTARG ;;
        w) OPT_WEEKLY=$OPTARG ;;
        m) OPT_MONTHLY=$OPTARG ;;
        o) OPT_DOW=$OPTARG ;;
        M) OPT_DOM=$OPTARG ;;
        l) LISTFILE=$OPTARG ;;
        h) usage 0 ;;
        *) usage 1 ;;
    esac
done

# --- Résolution du script à lire ---
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

# Lecture d'une valeur entière dans le script testé.
#
# On ne source PAS le fichier : cela déclencherait son analyse d'options, sa prise de verrou, et au bout du compte une vraie sauvegarde. 
# Un sed ancré suffit. Il s'arrête au premier match et valide au passage que la valeur est bien un entier. 
# L'ancrage sur "^NOM=" écarte les homonymes tels que DAILY_SEC, qui ne commencent pas par "DAILY=".

read_value() {
    _v=$("$SED_BIN" -n "/^$1=/{s/^$1=\([0-9][0-9]*\).*/\1/p;q;}" "$BACKUP_SCRIPT")
    [ -n "$_v" ] || die "valeur $1 introuvable ou non numérique dans $BACKUP_SCRIPT"
    printf '%s\n' "$_v"
}

DAILY=$(read_value DAILY)
WEEKLY=$(read_value WEEKLY)
MONTHLY=$(read_value MONTHLY)
DOW=$(read_value DOW)
DOM=$(read_value DOM)

# Les surcharges viennent après la lecture, pour pouvoir comparer un scénario
# à la configuration réelle sans toucher au script. Des if plutôt que des
# "[ ] && x=y" : sous set -e, un test faux en fin de commande tuerait le
# script.
if [ -n "$OPT_DAILY" ];   then DAILY=$OPT_DAILY;     fi
if [ -n "$OPT_WEEKLY" ];  then WEEKLY=$OPT_WEEKLY;   fi
if [ -n "$OPT_MONTHLY" ]; then MONTHLY=$OPT_MONTHLY; fi
if [ -n "$OPT_DOW" ];     then DOW=$OPT_DOW;         fi
if [ -n "$OPT_DOM" ];     then DOM=$OPT_DOM;         fi

# Memes calculs que le script teste : fenetres CUMULEES, chaque palier prend
# le relais la ou le precedent s arrete.
NOW_UNIX=$("$DATE_BIN" +%s)
DAILY_SEC=$((DAILY * 86400))
WEEKLY_SEC=$((DAILY_SEC + WEEKLY * 604800))
MONTHLY_UNIX=$(($("$DATE_BIN" -d "-${MONTHLY} months" +%s) - WEEKLY_SEC))

TMP=$(mktemp) || exit 1
trap 'rm -f "$TMP"' EXIT HUP INT TERM

printf 'tarsnap-backup : controle de coherence de la rotation\n'
printf -- '-----------------------------------------------------\n'
printf 'configuration lue dans %s\n\n' "$BACKUP_SCRIPT"
printf 'quotidien  DAILY=%-4s tout             de %5s a %5s j\n' \
    "$DAILY" 0 "$((DAILY_SEC / 86400))"
printf 'hebdo      WEEKLY=%-3s DOW=%s            de %5s a %5s j\n' \
    "$WEEKLY" "$DOW" "$((DAILY_SEC / 86400))" "$((WEEKLY_SEC / 86400))"
printf 'mensuel    MONTHLY=%-2s DOM=%-2s           de %5s a %5s j\n\n' \
    "$MONTHLY" "$DOM" "$((WEEKLY_SEC / 86400))" \
    "$(((NOW_UNIX - MONTHLY_UNIX) / 86400))"

# Invariant : chaque palier doit ouvrir une fenetre STRICTEMENT plus large que
# le precedent, sinon son test est inatteignable et le palier ne sert a rien.
# En fenetres cumulees l invariant est structurel : chaque borne est calculee
# a partir de la precedente, un palier ne peut plus etre avale par son voisin.
# Restent les cas ou un palier est mis a zero, donc desactive de fait.
ANOMALIE=0
if [ "$WEEKLY" -lt 1 ]; then
    ANOMALIE=1
    printf 'ATTENTION: WEEKLY=%s, le palier hebdomadaire est desactive.\n\n' \
        "$WEEKLY"
fi
if [ "$MONTHLY_UNIX" -ge "$((NOW_UNIX - WEEKLY_SEC))" ]; then
    ANOMALIE=1
    printf 'ATTENTION: MONTHLY=%s ne depasse pas la fenetre hebdomadaire,\n' \
        "$MONTHLY"
    printf '           le palier mensuel est desactive.\n\n'
fi

# Decision pour une archive, a partir de son epoch, son jour de semaine et son
# jour du mois. Ecrit le verdict dans DECISION : fils, pere, gpere ou purge.
decide() {
    _unix=$1; _dow=$2; _dom=$3
    _age=$((NOW_UNIX - _unix))
    if [ "$_age" -lt "$DAILY_SEC" ]; then
        DECISION=fils
    elif [ "$_dow" -eq "$DOW" ] && [ "$_age" -lt "$WEEKLY_SEC" ]; then
        DECISION=pere
    elif [ "$_dom" -eq "$DOM" ] && [ "$_unix" -gt "$MONTHLY_UNIX" ]; then
        DECISION=gpere
    else
        DECISION=purge
    fi
}

kd=0; kw=0; km=0; del=0; skip=0

if [ -n "$LISTFILE" ]; then
    ###########################################################################
    # MODE REJEU sur une vraie liste
    ###########################################################################
    COMPUTER=$("$UNAME_BIN" -n)
    if [ "$LISTFILE" = "-" ]; then
        cat > "$TMP"
    else
        cat "$LISTFILE" > "$TMP"
    fi

    printf 'Rejeu sur la liste reelle, hostname "%s" :\n\n' "$COMPUTER"

    while read -r archive; do
        [ -n "$archive" ] || continue
        case "$archive" in
            *.part)
                printf '  %-32s PARTIELLE, laissee en place\n' "$archive"
                skip=$((skip + 1)); continue ;;
            "${COMPUTER}-"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9]-[0-9][0-9])
                ;;
            *)
                printf '  %-32s hors motif, intouchable\n' "$archive"
                skip=$((skip + 1)); continue ;;
        esac

        stamp=${archive#"${COMPUTER}-"}
        day=${stamp%%_*}
        # shellcheck disable=SC2046
        set -- $("$DATE_BIN" -d "$day" '+%s %w %-d')
        decide "$1" "$2" "$3"

        case "$DECISION" in
            fils)  kd=$((kd + 1));   verdict="CONSERVEE  (fils, quotidien)" ;;
            pere)  kw=$((kw + 1));   verdict="CONSERVEE  (pere, hebdo)" ;;
            gpere) km=$((km + 1));   verdict="CONSERVEE  (grand-pere, mensuel)" ;;
            *)     del=$((del + 1)); verdict="SUPPRIMEE" ;;
        esac
        printf '  %-32s %s\n' "$archive" "$verdict"
    done < "$TMP"
    printf '\n'
else
    ###########################################################################
    # MODE SIMULATION
    ###########################################################################
    printf 'Simulation sur %s jours, une archive par jour...\n' "$DAYS"

    # Deux appels a date pour tout l historique, au lieu de quatre par jour :
    # la version precedente forkait 7300 fois pour 5 ans et donnait
    # l impression d etre plantee.
    # Premiere passe : les dates relatives deviennent des AAAA-MM-JJ.
    # Seconde passe : ces jours deviennent epoch de minuit, jour de semaine et
    # jour du mois, exactement comme le fait le script teste.
    i=0
    while [ "$i" -lt "$DAYS" ]; do
        printf -- '-%s days\n' "$i"
        i=$((i + 1))
    done | "$DATE_BIN" -f - +%F | "$DATE_BIN" -f - '+%s %w %-d' > "$TMP"

    while read -r f_unix f_dow f_dom; do
        decide "$f_unix" "$f_dow" "$f_dom"
        case "$DECISION" in
            fils)  kd=$((kd + 1)) ;;
            pere)  kw=$((kw + 1)) ;;
            gpere) km=$((km + 1)) ;;
            *)     del=$((del + 1)) ;;
        esac
    done < "$TMP"
    printf '\n'
fi

printf '  fils       (quotidien)  : %s\n' "$kd"
printf '  pere       (hebdo)      : %s\n' "$kw"
printf '  grand-pere (mensuel)    : %s\n' "$km"
printf '  supprimees              : %s\n' "$del"
[ "$skip" -gt 0 ] && printf '  hors perimetre          : %s\n' "$skip"
printf '  ----------------------------------\n'
printf '  conservees au total     : %s\n\n' "$((kd + kw + km))"

if [ "$kw" -eq 0 ] && [ "$ANOMALIE" -eq 1 ]; then
    printf 'CONCLUSION: le palier pere ne conserve rien.\n'
fi
if [ "$ANOMALIE" -eq 0 ] && [ -z "$LISTFILE" ]; then
    printf 'Les trois paliers sont actifs, la configuration est coherente.\n'
fi
exit 0
