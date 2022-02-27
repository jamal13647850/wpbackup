

rsync -azvrh --progress --exclude 'fm' --exclude 'wp-content/cache' --exclude 'wp-content/debug.log' --exclude 'wp-content/backups-dup-pro' --exclude 'nginx.conf' /var/www/html/** -e 'ssh -p [destport] -i /root/.ssh/id_rsa' [destuser]@[destip]:[destfilesbackuppath]



