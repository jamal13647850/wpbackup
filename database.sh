#!/usr/bin/env bash

SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
DIR=`date +"%Y%m%d-%H%M%S"`
DEST=$SCRIPTPATH/backups/$DIR
DBZIP='DB-'$DIR'.zip'

. $SCRIPTPATH/settings.conf




mkdir -pv $SCRIPTPATH/backups
#find $SCRIPTPATH/backups/ -mtime +"${BACKUP_RETAIN_DURATION}" -exec rm -rfv {} \;

mkdir -pv $DEST
mkdir -pv $DEST/DB


cd $DEST/DB
nice -n 19 wp db export --add-drop-table --path=$wpPath
cd $DEST
nice -n 19 zip -r9 $DBZIP DB/
nice -n 19 rm -rfv DB/


nice -n 19 rsync -azvrh --progress $DEST/$DBZIP -e "ssh -p ${destinationPort} -i ${privateKeyPath}" $destinationUser@$destinationIP:$destinationDbBackupPath

