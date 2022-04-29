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
wp db export --add-drop-table --path=/var/www/html
cd $DEST
zip -r9 $DBZIP DB/
rm -rfv DB/


mkdir -pv $DEST/Files
cp -rfv /var/www/html/* $DEST/Files
cd $DEST
zip -r9 $FILESZIP Files/
rm -rfv Files/

rsync -azvrh --progress $DEST/$DBZIP -e "ssh -p ${destinationPort} -i ${privateKeyPath}" $destinationUser@$destinationIP:$destinationDbBackupPath
rsync -azvrh --progress $DEST/$FILESZIP -e "ssh -p ${destinationPort} -i ${privateKeyPath}" $destinationUser@$destinationIP:$destinationFilesBackupPath


