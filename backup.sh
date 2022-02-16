SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
DIR=`date +"%Y%m%d-%H%M%S"`
DEST=$SCRIPTPATH/backups/$DIR
DBZIP='DB-'$DIR'.zip'
FILESZIP='Files-'$DIR'.zip'


mkdir -pv $SCRIPTPATH/backups
mkdir -pv $DEST
mkdir -pv $DEST/DB
mkdir -pv $DEST/Files

cd $DEST/DB
wp db export --add-drop-table --path=/var/www/html
cd $DEST
zip -r9 $DBZIP DB/
rm -rfv DB/


cp -rfv /var/www/html/* $DEST/Files
cd $DEST
zip -r9 $FILESZIP Files/
rm -rfv Files/

#ssh-keygen
#ssh-copy-id -i ~/.ssh/id_rsa.pub -p port [destuser]@[destip]

rsync -azvrh --progress $DEST/$DBZIP -e 'ssh -p [destport] -i /home/[srcuser]/.ssh/id_rsa' [destuser]@[destip]:[destbackuppath]
rsync -azvrh --progress $DEST/$FILESZIP -e 'ssh -p [destport] -i /home/[srcuser]/.ssh/id_rsa' [destuser]@[destip]:[destbackuppath]

#0 0 3 * * sh /path/to/backup.sh >>  /path/to/backup.log 2>&1
