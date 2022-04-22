SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
DIR=`date +"%Y%m%d-%H%M%S"`
DEST=$SCRIPTPATH/backups/$DIR
FILESZIP='Files-'$DIR'.zip'

. ./settings.conf


mkdir -pv $SCRIPTPATH/backups
find $SCRIPTPATH/backups/ -mtime +"${BACKUP_RETAIN_DURATION}" -exec rm -rfv {} \;


mkdir -pv $DEST


mkdir -pv $DEST/Files
cp -rfv /var/www/html/* $DEST/Files
cd $DEST
zip -r9 $FILESZIP Files/
rm -rfv Files/


rsync -azvrh --progress $DEST/$FILESZIP -e "ssh -p ${destinationPort} -i ${privateKeyPath}" $destinationUser@$destinationIP:$destinationFilesBackupPath

