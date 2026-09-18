[![License: CC0](https://img.shields.io/badge/license-CC0_1.0-lightgrey.svg?style=plastic)](https://creativecommons.org/publicdomain/zero/1.0/)
[![License: WTFPL](https://img.shields.io/badge/license-WTFPL_2.0-lightgrey.svg?style=plastic)](https://www.wtfpl.net/)
![Hack The Planet](https://img.shields.io/badge/hack-the--planet-black?style=plastic\&logo=Debian\&logoColor=white)
![Built With Love](https://img.shields.io/badge/built%20with-%E2%9D%A4%20by%20DeuZa-red?style=plastic)
![shellcheck](https://img.shields.io/badge/shellcheck-clean-brightgreen?style=plastic)

![GitHub release](https://img.shields.io/github/v/release/deuza/tarsnap-tools?label=release&style=plastic)
![GitHub Release Date](https://img.shields.io/github/release-date/deuza/tarsnap-tools&style=plastic)
[![GitHub last commit](https://img.shields.io/github/last-commit/deuza/tarsnap-tools?style=plastic)](https://github.com/deuza/tarsnap-backup/commits/main)
![GitHub commit activity](https://img.shields.io/github/commit-activity/t/deuza/tarsnap-tools?style=plastic)
![GitHub code size in bytes](https://img.shields.io/github/languages/code-size/deuza/tarsnap-tools?style=plastic)


# tarsnap-tools

Tarsnap Tools est une suite d'utilitaires pour Tarsnap utilisée par l'auteur au quotidien.

Sauvegarde [Tarsnap](https://www.tarsnap.com/), puis rotation grand-père/père/fils.   
Ecrit pour Debian, en `sh` strictement POSIX, sans dépendance à `bash`.

Le pilier est `tarsnap-backup.sh` qui s'occupe de faire vos sauvegardes, une fois configuré plus besoin d'y toucher.  
Il prépare ce qui doit l'être, crée une archive datée, puis purge les anciennes selon un schéma de rétention à trois paliers.

Trois outils l'accompagnent (aucun ne créant ni ne supprimant la moindre archive) :

| Script | Rôle |
|---|---|
| `tarsnap-backup.sh` | sauvegarde et rotation grand-père / père / fils |
| `rotation-check.sh` | vérifie la configuration de rétention, sans toucher à Tarsnap |
| `tarsnap-diff.sh` | compare un snapshot à l'état actuel du système |
| `tarsnap-stats.sh` | tailles, déduplication et coût de stockage |

Ces scripts ont été testés et développés avec la version 1.0.4 de Tarsnap sous Debian Trixie et sont utilisés quotidiennement par l'auteur.   
Ils sont commentés un maximum pour qu'ils puissent être compréhensibles, modifiés, adaptés etc.

## Sommaire

- [Ce que fait le script](#ce-que-fait-le-script)
- [Le schéma de rétention](#le-schéma-de-rétention)
- [Prérequis](#prérequis)
- [Installation](#installation)
- [Configuration](#configuration)
- [Préparer et nettoyer autour de la sauvegarde](#préparer-et-nettoyer-autour-de-la-sauvegarde)
- [Utilisation](#utilisation)
- [Les archives hors rotation](#les-archives-hors-rotation)
- [Vérifier sa configuration de rétention](#vérifier-sa-configuration-de-rétention)
- [Comparer un snapshot au système](#comparer-un-snapshot-au-système)
- [Statistiques et coût de stockage](#statistiques-et-coût-de-stockage)
- [Garanties de conception](#garanties-de-conception)
- [Choix techniques](#choix-techniques)
- [Limites connues](#limites-connues)
- [Restaurer](#restaurer)
- [License](#license)

## Ce que fait le script

À chaque exécution, dans cet ordre :

1. Il appelle `prebackup`, la fonction qui prépare le terrain. Par défaut elle régénère l'inventaire des paquets installés, `dpkg --get-selections` et `apt list --installed`, dans deux fichiers eux-mêmes embarqués dans la sauvegarde. Restaurer une machine sans savoir ce qui y était installé est une perte de temps évitable. C'est aussi là que vous placerez vos dumps de bases et vos appels à des scripts externes.
2. Il crée une archive Tarsnap nommée `hostname-AAAA-MM-JJ_HH-MM-SS`.
3. Il appelle `postbackup`, le pendant du premier : nettoyage des dumps temporaires, notification, redémarrage d'un service.
4. Il liste les archives existantes et supprime celles qui ne satisfont aucun des trois critères de rétention.

L'ordre est délibéré : on crée **avant** de détruire. Si Tarsnap échoue, pour cause de réseau, de quota ou de clé, `set -e` interrompt le script et aucune archive n'est supprimée.   
Le *pire* cas possible est donc "les anciennes archives s'accumulent", mais jamais "j'ai purgé et je ne fais rien".

## Le schéma de rétention

### Le principe

Grand-père/Père/Fils, est un schéma de rotation de bandes magnétiques, antérieur de plusieurs décennies aux sauvegardes en ligne (comme moi :).   
L'idée : plus une sauvegarde est ancienne, moins on a besoin de granularité : on conserve donc toutes les sauvegardes récentes, puis une par semaine, puis une par mois.

[Fiche Wikipédia](https://en.wikipedia.org/wiki/Backup_rotation_scheme#Grandfather-father-son)

### Les fenêtres sont cumulées

C'est le point qui mérite votre attention, parce que les deux lectures possibles donnent des résultats très différents.

Les trois fenêtres **se succèdent** au lieu de se recouvrir. Chaque palier prend le relais là où le précédent s'arrête. Avec les valeurs par défaut :

| Palier | Variable | Conserve | Couvre |
|---|---|---|---|
| Fils | `DAILY=90` | toutes les archives | de 0 à 90 jours |
| Père | `WEEKLY=12` | celles tombant un `DOW` | de 90 à 174 jours |
| Grand-père | `MONTHLY=48` | celles tombant un `DOM` | de 174 à 1635 jours |

La couverture totale est donc `DAILY` jours **plus** `WEEKLY` semaines **plus** `MONTHLY` mois, soit un peu plus de quatre ans et demi avec les valeurs livrées.

L'autre lecture possible, celle où les trois fenêtres seraient comptées depuis maintenant et non les unes à la suite des autres, n'a pas été retenue.   
Elle impose à l'utilisateur de respecter l'invariant `DAILY < WEEKLY × 7 < MONTHLY × 30`, faute de quoi un palier devient silencieusement inatteignable. 

Avec `DAILY=90` et `WEEKLY=12`, les 84 jours de la fenêtre hebdomadaire tiendraient entièrement dans les 90 jours de la fenêtre quotidienne, et le palier père ne conserverait jamais rien, sans le moindre message d'erreur. Les fenêtres cumulées rendent cet invariant structurel : il n'y a plus rien à vérifier.

### Une archive est conservée si elle satisfait au moins un critère

Les trois tests sont indépendants et évalués dans l'ordre. Le premier qui répond "oui" l'emporte, mais aucun n'exclut les autres.    
Concrètement, une archive datée du 1er du mois est conservée par le palier mensuel même si elle se trouve encore dans la plage de dates du palier hebdomadaire et qu'elle n'est pas un lundi.    

C'est le comportement attendu : les paliers définissent des raisons de garder, pas des tranches exclusives.

### Ce que ça donne concrètement

Sur cinq ans de sauvegardes quotidiennes, avec les valeurs par défaut :

```
  fils       (quotidien)  : 90
  père       (hebdo)      : 12
  grand-père (mensuel)    : 50
  supprimées              : 1673
  ----------------------------------
  conservées au total     : 152
```

Cent cinquante-deux archives conservées sur mille huit cent vingt-cinq.  
Ces chiffres sont ceux du script `rotation-check.sh` de diagnostic fourni, pas une estimation !

### Faut-il purger si peu ?

Tarsnap déduplique vos données.  
Une archive qui n'apporte aucune donnée nouvelle ne coûte que ses métadonnées non dédupliquées, soit environ 1 ko, plus 1 octet par fichier et 1 octet par Mo de données.  

Dans la plupart des cas cela reste sous les 10 ko, pour un coût de l'ordre de 0,0025 $ par mois.   
Vous pouvez donc être nettement plus généreux qu'à l'époque des bandes, où le coût marginal d'une sauvegarde était le prix de celle-ci.

[Pour plus d'informations sur la déduplication](https://www.tarsnap.com/deduplication-explanation)

## Prérequis

Debian, ou toute autre distribution GNU/Linux qui en dérive.   
Il suppose `usrmerge`, donc les binaires de base sous `/usr/bin`, et il appelle `dpkg` et `apt` pour l'inventaire des paquets.  
La syntaxe du shell, lui, est du `sh` strictement POSIX : aucune dépendance à `bash`, et tout passe sous le `dash` que Debian installe comme `/bin/sh` ainsi que `bash` et autre shells POSIX.

Il vous faut, dans l'ordre :

**Un compte Tarsnap et une clé** générée par `tarsnap-keygen`.

**Le client tarsnap**, à récupérer depuis [la page de téléchargement](https://www.tarsnap.com/download.html). 

(Si vous êtes sur une autre architecture i386 ou amd64 vous ne pourrez pas utiliser les .deb, si comme moi vous êtes sur Rapsberryi `aarch64` il faudra passer par là : [La page de construction du .deb](https://www.tarsnap.com/pkg-deb.html#tarsnap-source-package)).

Note : c'est le package `libext2fs-dev` qui fournit `ext2fs/ext2_fs.h`, réclamé par tarsnap et à ne pas confondre avec `linux/ext2_fs.h` !

**Les outils de base**, déjà présents sur une Debian standard : `flock` (util-linux), `date` et `sed` (coreutils et sed), `dpkg` et `apt`.

**La locale `en_US.UTF-8` doit être générée**, pour une sortie prédictible de tarsnap, d'`apt` et de `date`. Le script refuse de démarrer sans elle :

```sh
dpkg-reconfigure locales
```

### Autres systèmes

Le script n'est pas portable en l'état. 
Il devrait tourner sur une autre distribution "Debian like".

Si vous souhaitez faire un portage, l'inventaire `dpkg` et `apt` sont à remplacer en premier.   
N'hésitez pas à m'envoyer un petit message !

## Installation

```sh
git clone https://github.com/deuza/tarsnap-tools.git
cd tarsnap-tools
cp tarsnap-backup.sh /usr/local/sbin/
chown root:root /usr/local/sbin/tarsnap-backup.sh
chmod 0700 /usr/local/sbin/tarsnap-backup.sh
```

Le script tourne sous root et lit la clé Tarsnap : 0700 et rien de plus.

Les trois autres scripts sont additionnels et n'ont pas besoin d'être installés dans `/usr/local/sbin/`.   
Rendez-les exécutables et lancez-les depuis le dépôt cloné :

```sh
chmod +x rotation-check.sh tarsnap-diff.sh tarsnap-stats.sh
```

- `rotation-check.sh` simule votre configuration de rétention ou la rejoue avec vos données réelles. 
- `tarsnap-diff.sh` compare un snapshot à l'état actuel du système. 

Tous deux vont chercher leur configuration dans `tarsnap-backup.sh`, aux chemins attendus : 
- D'abord `/usr/local/sbin/tarsnap-backup.sh` 
- Puis, à défaut, un `tarsnap-backup.sh` voisin dans leur propre répertoire.

- `tarsnap-stats.sh`, lui, ne lit rien de tout ça : il se repose sur votre `tarsnap.conf` et n'a aucune configuration.

Éditez ensuite le bloc de configuration en tête de fichier (section suivante), puis vérifiez la syntaxe avec `--dry-run` pour empêcher toute création de snapshot :

```sh
sh -n /usr/local/sbin/tarsnap-backup.sh
/usr/local/sbin/tarsnap-backup.sh --dry-run --verbose
```

Une fois satisfait, placez le dans la crontab de root :

```
2 0 * * * /usr/local/sbin/tarsnap-backup.sh
```

Ou dans le fichier `/etc/crontab` : 

```
02 00   * * *   root /usr/local/sbin/tarsnap-backup.sh
```

Sans `--verbose`, le script est silencieux en fonctionnement normal.  
Seules les erreurs et les avertissements partent sur la sortie d'erreur, soit dans le courriel de `cron` ou autre selon votre configuration.

## Configuration

Tout se règle dans le bloc en tête de fichier, entre `CONFIGURATION` et `FIN DE LA CONFIGURATION`.

### Chemins des binaires

`TARSNAP_BIN`, `DATE_BIN`, `UNAME_BIN`, `LOCALE_BIN`, `GREP_BIN`, `DPKG_BIN`, `APT_BIN`, `FLOCK_BIN`.

Le chemin des binaires est écrits en dur pour ne pas dépendre du `PATH` de l'appelant, que ce soit `cron`, `systemd` ou un `sudo` mal réglé.   
Les valeurs livrées sont celles de Debian avec `usrmerge`, donc tout sous `/usr/bin`. Le script vérifie au démarrage que chacun est exécutable et refuse de tourner sinon.

### Tarsnap

`TARSNAP_KEY` : il s'agit du chemin de la clé de Tarsnap. Laissez la variable vide pour vous en remettre au `keyfile` déclaré dans `tarsnap.conf`.    
Une seule clé suffit : côté Tarsnap, la permission de suppression implique celle de lecture, une clé en lecture seule séparée ne serait qu'un sous-ensemble strict.

Le `cachedir`, lui, n'est pas passé en ligne de commande. Il est lu dans `tarsnap.conf`.

Vous pouvez vérifier tout ça avec les commandes suivantes : 

```
root@foo:~/tarsnap-backup# tarsnap --dump-config
Command-line:
  tarsnap --dump-config
Reading from config file: /root/.tarsnaprc
Reading from config file: /root/.config/tarsnap/tarsnap.conf
Reading from config file: /etc/tarsnap.conf
  cachedir /usr/local/tarsnap-cache
  keyfile /root/tarsnap.key
  nodump
  print-stats
  checkpoint-bytes 1G
root@foo:~/tarsnap-backup#
```

Vous pouvez également vérifier votre configuration de Tarsnap :

```
root@foo:~/tarsnap-backup# tarsnap --verify-config
root@foo:~/tarsnap-backup# echo $?
0
root@foo:~/tarsnap-backup#
```

### Contenu de la sauvegarde

- `BACKUP_DIRS` : répertoires à embarquer, séparés par des espaces.    
- `BACKUP_EXCLUDE` : motifs d'exclusion, séparés par des espaces. 

Deux formes sont acceptées :

1. Un chemin absolu, par exemple `/var/www/html/APOD`, donc ancré et sans effet de bord. 
2. Un motif globbé, par exemple `*/tmp/*`, passé tel quel à Tarsnap ;

Tarsnap utilise la syntaxe de `bsdtar`, il retire le `/` de tête des noms d'entrée, le script fait la conversion et génère les deux motifs nécessaires, celui du répertoire et celui de son contenu.

### Rétention

`DAILY`, `WEEKLY`, `MONTHLY`, `DOW`, `DOM`. Voir [le schéma de rétention](#le-schéma-de-rétention) ci-dessus.

`DOW` vaut 0 pour dimanche, 1 pour lundi. `DOM` est le quantième conservé, 1 par défaut.    
Évitez 29, 30 et 31 comme `DOM` : les mois qui ne les contiennent pas ne verront aucune archive retenue !

Mettre `WEEKLY` ou `MONTHLY` à 0 désactivera le palier correspondant : Le script de diagnostic `rotation-check.sh` vous avertira.

### Divers

`LOCK_FILE` : verrou d'exécution, dans `/run` par défaut.  
Ni `/tmp` ni `/run/lock`, qui sont en 1777 : car n'importe quel utilisateur local pourrait y tenir le verrou et bloquer indéfiniment vos sauvegardes !!!

`PKG_SELECTIONS` et `PKG_LIST` : les deux fichiers d'inventaire produits par `prebackup`.  
Placez-les dans un répertoire couvert par `BACKUP_DIRS`, sinon ils ne partiront pas dans l'archive.

## Préparer et nettoyer autour de la sauvegarde

Deux fonctions encadrent la création de l'archive. Elles se trouvent juste après le bloc de configuration et sont faites pour être éditées.

### `prebackup`

Tout ce qui doit être préparé avant que Tarsnap ne lise les fichiers : inventaires, dumps de bases, export de configuration, appel à un script externe. 
Livré avec l'inventaire des paquets et une série d'exemples commentés à adapter selon vos besoins :

```sh
prebackup() {
    say "Inventaire des paquets installés."
    "$DPKG_BIN" --get-selections > "$PKG_SELECTIONS"
    "$APT_BIN" list --installed 2>/dev/null > "$PKG_LIST"

    # say "Dump des bases MySQL."
    # /usr/bin/mysqldump --all-databases --single-transaction --quick \
    #     --events --routines > /root/dumps/mysql-all.sql

    return 0
}
```

Déclarez le chemin absolu de vos binaires en tête de script, comme les autres, plutôt que de vous en remettre au `PATH`.    
Et pour MySQL, les identifiants vont dans un `~/.my.cnf` en 0600, jamais sur la ligne de commande où `ps` les rendrait visibles de tous les utilisateurs de la machine.

### `postbackup`

Le pendant, exécuté une fois l'archive créée, snapshot compris, et avant la rotation.    
Nettoyage des dumps temporaires, notification, redémarrage d'un service arrêté par `prebackup`. 

Il est vide par défaut, avec ses exemples commentés.

### Les deux règles à retenir

**La fonction doit rendre 0.** 

Toute autre valeur, et toute commande qui échoue à l'intérieur, arrête le script :   
- Pour `prebackup` cela se produit **avant** la création de l'archive, donc avant la moindre suppression : mieux vaut ne rien sauvegarder que sauvegarder une base à moitié dumpée.   
- Pour `postbackup`, l'archive est déjà en place et c'est la rotation qui est sautée, donc les anciennes archives s'accumulent. 

Dans les deux cas, le sens de panne est le bon.

### Les deux fonctions sont exécutées aussi en `--dry-run` :

C'est voulu : une simulation qui ne préparerait pas les mêmes fichiers ne simulerait pas grand-chose, puisque c'est exactement ce que Tarsnap est censé lire.   
Conséquence pratique à ne pas découvrir en production : si vous y placez un dump de plusieurs gigaoctets, commentez-le avant d'enchaîner les essais à blanc, sinon chaque `--dry-run` le rejoue en entier.

## Utilisation

```
usage: tarsnap-backup.sh [-d|-n|--dry-run] [-v|--verbose] [-h|--help]
       tarsnap-backup.sh [-s|--snapshot-name] NOM
       tarsnap-backup.sh [-o|--orphans]
```

`-d`, `-n`, `--dry-run` : simulation complète. Rien n'est créé ni supprimé, et la commande de purge qui serait exécutée est affichée.   
Attention, la création est simulée par `tarsnap --dry-run`, qui lit réellement les fichiers : c'est aussi long qu'une exécution réelle. 

**Notez que le `-d` du script signifie "ne supprime rien", soit l'exact opposé du `-d` de Tarsnap : `-n` est accepté en synonyme et reste la forme la moins ambiguë.**

`-v`, `--verbose` : détaille la décision prise pour chaque archive, et passe `-v` à Tarsnap.

`-s NOM`, `--snapshot-name NOM` : crée une archive suffixée par `NOM`, puis sort sans faire de rotation.   
Le suffixe la fait sortir du motif testé par la purge, elle devient donc définitivement intouchable par le script. 
**C'est ce qu'il faut utiliser avant une mise en production par exemple.**   

Les caractères admis sont `A-Z`, `a-z`, `0-9`, `_` et `-`. La forme `--snapshot-name=NOM` est également acceptée.

`-o`, `--orphans` : liste les archives hors de portée de la rotation, puis sort. Voir la section suivante.

`-h`, `--help` : affiche l'aide.

## Les archives hors rotation

Tout le reste lui est invisible, et le restera.   
C'est une garantie, mais c'est aussi une façon d'accumuler sans s'en rendre compte des archives orphelines que plus rien ne nettoie.

```sh
tarsnap-backup.sh --orphans
```

L'option est en lecture seule : elle ne crée rien, ne supprime rien, et ne pose même pas de verrou.   
*Vous pouvez donc l'appeler pendant qu'une sauvegarde tourne en tâche de fond.*

Elle distingue deux familles, pour deux raisons différentes :

**- Les snapshots orphelins :**   
Leurs noms ne correspond pas au motif des snapshots créés par `tarsnap-backup.sh`, donc la purge les exclus d'office.  

On y trouve l'ensemble des snapshots créés avec la clef de Tarsnap, la purge ne touche **QUE** ce qui respecte EXACTEMENT le motif : **`hostname-AAAA-MM-JJ_HH-MM-SS`**   

**- Les partielles :**   
Suffixées `.part`, ce sont les vestiges d'une exécution interrompue dont Tarsnap a récupéré un checkpoint. 

Elles sont prise en compte pour la déduplication et peuvent contenir des données qui ne sont nulle part ailleurs.   
Le script les signale déjà sur la sortie d'erreur à chaque rotation. L'option `--orphans` les regroupe pour que vous puissiez trancher à froid.

Pour chaque famille, la commande de suppression correspondante est affichée, prête à être relue puis collée.   
Elle ne sera jamais exécutée par le script :

```
--- Orphelines : nom hors motif, jamais purgees ---
  foo-2026-01-10_03-00-00_avant-prod
  vieux-backup-a-la-main
  bar-2024-02-01_02-00-00

  Suppression, a relire avant de la coller :
  /usr/bin/tarsnap --keyfile /root/tarsnap.key -d -f foo-2026-01-10_03-00-00_avant-prod -f vieux-backup-a-la-main -f bar-2024-02-01_02-00-00
```

## Vérifier sa configuration de rétention

Le dépôt inclus le script `rotation-check.sh` qui rejoue la logique de décision de la rotation. Il ne touche ni à Tarsnap, ni au réseau, ni à la moindre archive.  
Les valeurs de rétention, sont issus du fichier `tarsnap-backup.sh`. 

L'ordre de recherche est `/usr/local/sbin/tarsnap-backup.sh`, puis, à défaut, un `tarsnap-backup.sh` présent dans le répertoire de travail (ce qui couvre le cas du dépôt fraîchement cloné)   

L'option `-f` court-circuite les deux.  
Le fichier n'est jamais sourcé par le script, seulement lu : le sourcer déclencherait son analyse d'options, son verrou et au bout du compte, une vraie sauvegarde.

L'outil est indispensable sur une machine récente : tant que toutes vos archives tiennent dans la fenêtre quotidienne, un `--dry-run` réel affichera "rien à purger" et ne prouvera rigoureusement rien.

Simuler cinq ans de sauvegardes quotidiennes avec votre configuration :

```sh
./rotation-check.sh
```

Comparer un autre réglage sans rien modifier :

```sh
./rotation-check.sh -d 30 -w 26 -m 60
```

Rejouer la décision sur vos archives **réelles** :

```sh
tarsnap --list-archives | ./rotation-check.sh -l -
```

La sortie commence par afficher d'où vient la configuration, puis affiche les trois plages :

```
configuration lue dans /usr/local/sbin/tarsnap-backup.sh

quotidien  DAILY=90   tout             de     0 a    90 j
hebdo      WEEKLY=12  DOW=1            de    90 a   174 j
mensuel    MONTHLY=48 DOM=1            de   174 a  1635 j
```

## Comparer un snapshot au système

Le dépôt inclut également le script `tarsnap-diff.sh`, qui compare un snapshot Tarsnap à l'état actuel de la machine et vous dit ce qui a bougé depuis.

Il se limite au périmètre réellement sauvegardé : `BACKUP_DIRS`, `BACKUP_EXCLUDE` et `TARSNAP_KEY` sont lus dans `tarsnap-backup.sh`, avec le même ordre de recherche que `rotation-check.sh` et la même précaution, le fichier n'est jamais sourcé.

Aucune archive n'est touchée.   
Seuls `-tv` et `-x` sont employés, tous deux en lecture seule côté Tarsnap : *"Extracting or listing archives may be performed in parallel with any other operation"*.   
Le script ne pose donc aucun verrou, et vous pouvez l'appeler pendant qu'une sauvegarde tourne.

### Les quatre catégories

La notation est celle de `diff`.

| Préfixe | Catégorie | Signification |
|---|---|---|
| `<` | supprimé | présent dans le snapshot, absent du système |
| `>` | nouveau | présent sur le système, absent du snapshot |
| `=` | identique | présent des deux côtés, contenu jugé identique |
| `*` | modifié | présent des deux côtés, contenu jugé différent |

Sans option, les quatre sont retenues. `-d`, `-n`, `-i` et `-m` les sélectionnent et se cumulent : `-dn` , par exemple, n'affichera que les supprimés et les nouveaux.

### Comment le verdict est rendu

C'est le point qui mérite votre attention, parce qu'il détermine ce que l'outil vous coûte.

Le listing d'une archive donne le type, la taille et la date de modification de chaque entrée. Rien d'autre, et surtout aucune somme de contrôle !  
Comparer deux contenus impose donc de rapatrier celui du snapshot, ce qui se paie en temps et en bande passante facturée. D'où trois cas, dont un seul touche au réseau.

| Situation | Verdict | Réseau |
|---|---|---|
| Tailles différentes | `*` modifié | aucun |
| Tailles égales, `mtime` égal | `=` identique | aucun |
| Tailles égales, `mtime` différent | départagé octet à octet | rapatriement |

Deux tailles différentes impliquent deux contenus différents : le cas est tranché gratuitement, et c'est de loin le plus fréquent.

Deux métadonnées concordantes valent `=`, par heuristique assumée comme telle. Un fichier réécrit avec exactement la même taille, puis dont le `mtime` serait remis à sa valeur d'origine, passerait au travers. Il faut le faire exprès, et `--strict` est là pour ceux que ça ne satisfait pas.

Reste le cas ambigu, le seul à justifier une lecture réelle.   
Le fichier est rapatrié puis comparé octet à octet : c'est ce qui élimine le faux `*` du fichier simplement touché par un `touch`, un `chmod` changé, une restauration etc.

Les fichiers à rapatrier sont d'abord rassemblés, puis extraits en **une seule** invocation de Tarsnap, via l'option `-T` qui lit la liste des noms dans un fichier.   
Une invocation par fichier rouvrirait l'archive côté serveur à chaque fois, ce qui devient ruineux dès la centaine de fichiers.

### Le mode strict

`-S` rapatrie et compare octet à octet **tous** les fichiers réguliers communs, y compris ceux dont les métadonnées concordent.   
C'est la seule garantie absolue, mais ça télécharge l'intégralité de la partie commune du snapshot. 

**A réserver à une vérification ponctuelle, et certainement pas à `cron` !!**

L'extraction se fait dans un répertoire temporaire sous `${TMPDIR:-/tmp}`. Si `/tmp` n'a pas la place, pointez `TMPDIR` ailleurs :

```sh
TMPDIR=/var/tmp ./tarsnap-diff.sh -S www-2026-08-27_00-02-02
```

Sans `-i` ni `-m`, `-S` n'a rien à renforcer : il est alors inerte, et le script vous le signale plutôt que de l'ignorer en silence.

### Ne demander qu'une catégorie coûte moins cher

Le rapatriement ne sert qu'à départager `=` de `*`. Si vous n'avez demandé ni l'un ni l'autre, il est court-circuité et l'exécution devient purement locale une fois le listing obtenu.

```sh
./tarsnap-diff.sh -d www-2026-08-27_00-02-02       # aucun rapatriement
./tarsnap-diff.sh -dn www-2026-08-27_00-02-02      # aucun rapatriement non plus
```

Les compteurs `<` et `>` restent exacts dans tous les cas, ne dépendant d'aucun rapatriement.   
Les compteurs `=` et `*`, eux, retombent alors sur les seules métadonnées : ils sont annoncés comme indicatifs, à l'écran comme dans le journal.

Les autres étapes ne sont pas économisables. "supprimé" et "nouveau" se déduisent du rapprochement des deux inventaires complets : il faut donc lister l'archive **et** parcourir le système, quelle que soit la catégorie demandée.

### Le journal

Sur une machine en production depuis un certain temps, le diff fait des dizaines de milliers de lignes, et le tampon d'un terminal n'est pas un outil d'analyse.   
Le détail est donc écrit dans un fichier, `/var/log/tarsnap-diff.sh-<snapshot>.log` (par défaut), et seul le résumé chiffré s'affiche :

```
root@foo :~# ./tarsnap-diff.sh foo-2026-07-27_00-02-05
Diff de foo-2026-07-27_00-02-05

  supprimes   (<) : 9
  nouveaux    (>) : 3325
  identiques  (=) : 30659
  modifies    (*) : 48
  --------------------------------
  total           : 34041

Detail : /var/log/tarsnap-diff.sh-foo-2026-07-27_00-02-05.log
```

Le journal porte les mêmes chiffres en tête, de sorte qu'un `head -11` vous résumera tout le contexte :

```
root@foo:~/tarsnap-tools# head -11 /var/log/tarsnap-diff.sh-foo-2026-08-20_00-02-02.log
# tarsnap-diff.sh
# snapshot    : foo-2026-08-20_00-02-02
# date        : 2026-09-19 00:14:34
# repertoires : /root /boot /var/www /etc
# exclusions  : */tmp/* /var/www/html/APOD
# mode        : hybride, octet a octet si taille egale et mtime different
#
# supprimes  (<) : 9
# nouveaux   (>) : 3417
# identiques (=) : 30663
# modifies   (*) : 52
root@foo:~/tarsnap-tools# 
```

Il est en texte nu, sans séquence ANSI : c'est un fichier fait pour être grepé :

```sh
grep '^\*' /var/log/tarsnap-diff.sh-foo-2026-07-27_00-02-05.log   # les fichiers modifiés
grep -c '^>' /var/log/tarsnap-diff.sh-foo-2026-07-27_00-02-05.log # combien de nouveaux fichiers
```

Les lignes de détail sont écrites au fil de l'eau sur un descripteur gardé ouvert, vous pouvez donc suivre la construction du diff depuis un autre terminal :

```sh
tail -f /var/log/tarsnap-diff.sh-foo-2026-07-27_00-02-05.log
```

L'en-tête, lui, ne peut évidemment être écrit qu'une fois les compteurs connus.  
Il est donc préfixé à la toute fin, par réécriture dans un fichier voisin puis renommage.   
L'opération est atomique, le journal n'est jamais laissé tronqué, mais elle change d'inode : un `tail -f` lancé pendant l'exécution suit l'ancien fichier et devra être relancé pour voir l'en-tête.

Ne placez pas le journal dans un répertoire couvert par `BACKUP_DIRS` : celui-çi ressortirait dans son propre diff en nouveau fichier.   
Le script vous prévient si vous lui donnez un chemin absolu qui tombe dedans.

### Options et exemples

```
usage: tarsnap-diff.sh [-d] [-n] [-i] [-m] [-S] [-v] [-e "motifs"]
                       [-l journal] [-f script] [--debug] SNAPSHOT
```

| Option | Effet |
|---|---|
| `-d`, `--deleted` | retient les fichiers supprimés depuis le snapshot |
| `-n`, `--new` | retient les nouveaux fichiers, absents du snapshot |
| `-i`, `--identical` | retient les fichiers identiques |
| `-m`, `--modified` | retient les fichiers modifiés |
| `-S`, `--strict` | compare octet à octet **tous** les fichiers communs |
| `-v`, `--verbose` | détaille la progression sur la sortie d'erreur |
| `-e`, `--exclude` | surcharge `BACKUP_EXCLUDE` |
| `-l`, `--log` | chemin du journal |
| `-f`, `--file` | chemin de `tarsnap-backup.sh` |
| `--debug` | trace d'exécution, et conservation du répertoire temporaire |
| `-h`, `--help` | affiche l'aide |

`SNAPSHOT` est le nom exact d'une archive existante, que liste `tarsnap --list-archives`.

Quelques exemples :

```sh
./tarsnap-diff.sh foo-2026-08-27_00-02-02                    # les quatre catégories
./tarsnap-diff.sh -m foo-2026-08-27_00-02-02                 # seulement les modifiés
./tarsnap-diff.sh -dn foo-2026-08-27_00-02-02                # supprimés et nouveaux
./tarsnap-diff.sh -S -m foo-2026-08-27_00-02-02              # modifiés, vérification stricte
./tarsnap-diff.sh -e "*/cache/*" foo-2026-08-27_00-02-02     # autres exclusions
```

**L'option `-e` mérite une explication détaillée :**  
Les exclusions au moment du snapshot ne sont pas reconstituables : le script appliquera forcément celles d'aujourd'hui ...   
Si elles ont changé depuis, `-e` vous permet justement de rejouer les anciennes exclusions.

### Limites de tarsnap-diff.sh

**Répertoires et liens symboliques : seule leur présence est comparée.**    
S'ils existent des deux côtés ils sont comptés `=`, sans notion de modification.   

Le listing ne donne pas de quoi juger un changement de cible de lien ou de permissions de répertoire de façon fiable.   
Périphériques, sockets et tubes nommés sont ignorés et n'ont rien à faire dans `BACKUP_DIRS`.

**Le système vit pendant le parcours :** Deux exécutions successives peuvent différer d'une unité sans que rien d'anormal ne se soit produit : un fichier temporaire créé puis détruit entre les deux suffit.

**Les mêmes dépendances GNU que le reste de la suite :** `find -printf`, `sed -i` et l'extension `%T` des formats de `find`.   

**La comparaison porte sur le contenu, pas sur les métadonnées :** Un fichier dont seules les permissions ou le propriétaire auraient changé sort en `=`.

## Statistiques et coût de stockage

`tarsnap-stats.sh` complète la suite par le versant comptable : nombre de snapshots, tailles, taux de déduplication et coût mensuel réel.

```
root@foo:~# ./tarsnap-stats.sh
All archives:
  Snapshots:        46
  Total size:       647.23 GB
  Compressed size:  619.83 GB
  Ratio:            95.8%

Unique data:
  Total size:       9.21 GB
  Encoded size:     8.57 GB
  Ratio:            93.0%

Storage cost:
  Monthly:          $2.1417
  Daily:            $0.071391 (30-day month)
  (250 pUSD/byte/month of encoded data)
root@foo:~# 
```

C'est là que le choix de rétention se chiffre :  
La section [Faut-il purger si peu ?](#faut-il-purger-si-peu-) explique pourquoi une archive redondante ne coûte presque rien.   
Cet outil vous donne le "presque" sur votre propre compte.

Un seul appel réseau est effectué, `--list-archives`, et uniquement pour compter les snapshots : `--print-stats` est calculé localement à partir du `cachedir`.    
Ne le mettez pas dans un `cron` pour autant, `--list-archives` télécharge et déchiffre l'intégralité des métadonnées d'archives à chaque exécution, pour des chiffres qui ne bougent qu'à la création ou à la suppression d'une archive.

Ce script a son propre dépôt, [github.com/deuza/tarsnap-stats](https://github.com/deuza/tarsnap-stats), où sa documentation complète est maintenue : options, codes de sortie, et la vérification à la main de chacun des chiffres à partir de la sortie brute de Tarsnap.   

Il est également référencé sur la [page des helper scripts de Tarsnap](https://www.tarsnap.com/helper-scripts.html), dans la section *Other Tarsnap-related tools*.  
Note: il est publié sous `CC0` seule, et non sous le double `CC0`/`WTFPL` du reste de ce dépôt.

## Garanties de conception

- **Création avant suppression.** Jamais l'inverse, en aucune circonstance.
- **`set -euf`.** Sortie à la première erreur, variable non définie fatale, pas de glob sur les expansions non quotées.
- **Verrou `flock` sur le descripteur 9.** Le manuel de Tarsnap interdit deux opérations de création ou de suppression concurrentes avec la même clé. Le verrou est porté par un descripteur ouvert, donc le noyau le libère à la mort du processus, y compris sur `kill -9`, sur OOM ou sur coupure de courant. Pas de fichier fantôme à nettoyer, et pas de course possible contrairement à un test d'existence suivi d'un `touch`.
- **Purge groupée en un seul appel.** Le manuel autorise `-f` répété en mode `-d`, et Tarsnap met les métadonnées en cache, ce qui accélère nettement une purge de plusieurs archives.
- **Motif de nommage strict comme garde-fou.** Ce qui ne correspond pas exactement au motif n'est jamais supprimé.

## Choix techniques

**Les fonctions `prebackup` et `postbackup` sont appelées nues, sans condition que les appels externes rendent correctement la main.** 

L'appel `set -e` en haut du script arrête le script sur la commande fautive, il ne poursuit pas la création du snapshot.  
Aucun message d'erreur maison, mais juste celui de la commande fautive, c'est beaucoup plus sûr car l'ensemble des erreurs sont ainsi catchées.

Avant de rajouter une commande ou un script dans un de ces blocs assurez vous que son execution se déroule donc correctement en utilisant l'option `--dry-run` et en surveillant qu'aucun mail n'apparait dans le courriel de `cron` ou en mode `--verbose`.

--- 

### Appel de l'option **`--dry-run` et non `--dry-run-metadata`** de Tarnsap :   

Cette dernière, ajoutée en Tarsnap 1.0.41, serait pourtant bien plus rapide : elle ne lit aucune donnée, là où `--dry-run` relit l'intégralité des fichiers et prend donc autant de temps qu'une sauvegarde réelle.   
Elle est écartée parce qu'elle échoue dès que le cache de chunks est peuplé.

```
tarsnap: Programmer error: writetape_writechunk unexpectedly returned 0
tarsnap: Error writing cached archive entry
```

Reproduit en 1.0.41 sur chacun des quatre répertoires de `BACKUP_DIRS` pris isolément, avec un `cachedir` issu d'une vraie sauvegarde.   
Le même appel contre un `cachedir` fraîchement initialisé passe sans broncher, ce qui isole le cache comme seule variable. Ce n'est pas non plus une question de volume, `/boot` seul suffit.   

Et `print-stats` n'y est pour rien :    
L'échec se produit aussi avec `--no-print-stats`. À noter tout de même, un fichier isolé passé en argument ne suffit pas toujours à déclencher l'erreur, même présent dans le cache : il faut que celui-ci puisse fournir une entrée d'archive complète.

La cause est visible dans le source de la 1.0.41. `multitape_write.c:429` pose `no_chunkifiers = (dryrun == 2)`, ce qui prive de chunkifier les flux initialisés lignes 517 à 521, alors que la couche chunks `d->C` est créée sans condition sur `dryrun` ligne 503. `writetape_ischunkpresent` répond donc "présent" là où `writetape_writechunk` rend 0, et `ccache_entry.c:409` traite ce 0 comme une erreur de programmation.

Ne remettez pas l'option sans avoir vérifié que cela à été corrigé en amont.   
La commande qui reproduit, en lecture seule et sur une copie du cache :

```sh
cp -a /usr/local/tarsnap-cache /root/ts-cache-test
tarsnap --cachedir /root/ts-cache-test --dry-run-metadata --no-print-stats -c -f zz-test /boot
echo $?
```

---  

Utilisation des arguments de Tarsnap **`--quiet --no-print-stats` pour que le script tourne en mode silencieux sans l'affichage systèmatique du tableau de sortie d'execution.   
La seule cause où le script est bavard c'est en cas d'erreur.

Utilisation de **`printf` et non de la commande `echo`:   
** Le comportement d'`echo` sur un contre-oblique ou sur un argument commençant par `-` peut varier d'un shell à l'autre, là où `printf` ne pose pas soucis**


**Options longues traduites à la main.** `getopts` POSIX ne connaît que les options d'un caractère.    
Le script réécrit les formes longues en formes courtes avant de lancer `getopts`, en acceptant un ou deux tirets.

## Limites connues

**La rotation étant ancrée sur `uname -n`** renommer la machine ou passer du nom court au nom pleinement qualifié, fait sortir toutes les archives antérieures du motif testé.    
Elles deviennent immortelles et devront être purgées à la main : `--orphans` vous les listera.   
Si vous prévoyez un renommage, videz d'abord, ou acceptez de garder l'historique.

**Le script est spécifique aux distributions Debian-like :** `dpkg` et `apt` figurent parmi les binaires obligatoires, et les appels à `date` reposent sur les extensions GNU `-d` et `%-d`.   
Ailleurs, il refusera de démarrer tant que le bloc de configuration et l'inventaire des paquets n'auront pas été adaptés. 

**Le code de sortie 2 de Tarsnap n'est pas distingué :** Tarsnap l'emploie pour signaler une erreur survenue alors que l'état côté serveur avait déjà été modifié.   
Le `set -e` le traite comme n'importe quelle autre erreur.

## Restaurer

Une sauvegarde qu'on n'a jamais restaurée n'est pas une sauvegarde :)

Prenez l'habitude de vérifier, par exemple une fois par trimestre :

```sh
tarsnap --list-archives                                # choisir une archive dans la liste
tarsnap -tv -f hostname-AAAA-MM-JJ_HH-MM-SS            # inspecter son contenu
mkdir /tmp/restore && cd /tmp/restore                  # créer un répertoire temporaire pour effecture la restauration
tarsnap -x -f hostname-AAAA-MM-JJ_HH-MM-SS etc/fstab   # restauration uniquement du fichier `/etc/fstab` du snapshot dans le répertoire courant 
```

**Tarsnap retire le `/` de tête des noms d'entrée, (comme `bsdtar`) les chemins à extraire sont donc relatifs : `etc/fstab` et non `/etc/fstab`.**   
Le fichier restauré sera donc situé dans `/tmp/restore/etc/fstab` il n'écrasera **JAMAIS** l'original !

## License

[![CC0](https://mirrors.creativecommons.org/presskit/buttons/88x31/svg/cc-zero.svg)](https://creativecommons.org/publicdomain/zero/1.0/)    [![WTFPL](http://www.wtfpl.net/wp-content/uploads/2012/12/wtfpl-badge-1.png)](http://www.wtfpl.net/)

`CC0 1.0 Universal` -- Public Domain -- [LICENSE](LICENSE).
`WTFPL` -- Do What The Fuck You Want To Public License, version 2 -- [LICENSE-WTFPL](LICENSE-WTFPL).

A une exception près : `tarsnap-stats.sh`, qui vient de [son propre dépôt](https://github.com/deuza/tarsnap-stats), est publié sous `CC0` seule, mais faites en ce que vous voulez :D


<p align="center">With ❤️ by <a href="https://github.com/deuza">DeuZa</a></p>
