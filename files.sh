SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
DIR=`date +"%Y%m%d-%H%M%S"`
DEST=$SCRIPTPATH/backups/$DIR
DBZIP='DB-'$DIR'.zip'
BACKUP_RETAIN_DURATION=10


#ssh-keygen
#ssh-copy-id -i ~/.ssh/id_rsa.pub -p port [destuser]@[destip]

rsync -azvrh --progress --exclude 'fm' --exclude 'nginx.conf' /var/www/html/** -e 'ssh -p [destport] -i /root/.ssh/id_rsa' [destuser]@[destip]:[destfilesbackuppath]



#0 21 * * * sh /path/to/backup.sh >>  /path/to/backup.log 2>&1

#0 21 * * * sh /var/www/backups/backup.sh >>  /var/www/backups/backup.log 2>&1
