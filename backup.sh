#!/usr/bin/env bash

SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
DIR=`date +"%Y%m%d-%H%M%S"`
DEST=$SCRIPTPATH/backups/$DIR
DBZIP='DB-'$DIR'.zip'
FILESZIP='Files-'$DIR'.zip'

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


mkdir -pv $DEST/Files
#cp -rfv $wpPath/* $DEST/Files
nice -n 19 rsync -av --progress --max-size=$maxSize --exclude 'wp-staging' --exclude '*.log' --exclude 'cache' --exclude 'wpo-cache' $wpPath/** $DEST/Files
cd $DEST
nice -n 19 zip -r9 $FILESZIP Files/
nice -n 19 rm -rfv Files/

nice -n 19 rsync -azvrh --progress $DEST/$DBZIP -e "ssh -p ${destinationPort} -i ${privateKeyPath}" $destinationUser@$destinationIP:$destinationDbBackupPath
nice -n 19 rsync -azvrh --progress $DEST/$FILESZIP -e "ssh -p ${destinationPort} -i ${privateKeyPath}" $destinationUser@$destinationIP:$destinationFilesBackupPath


