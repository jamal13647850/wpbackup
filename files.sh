

rsync -azvrh --progress --exclude 'fm' --exclude 'nginx.conf' /var/www/html/** -e 'ssh -p [destport] -i /root/.ssh/id_rsa' [destuser]@[destip]:[destfilesbackuppath]



