#!/usr/bin/env bash
DIR=`date +"%Y%m%d-%H%M%S"`
DownloadedBackup=DownloadedBackup$DIR
. ./settings.conf

mkdir -p $DownloadedBackup
#rsync -azvrh --progress -e "ssh -p ${destinationPort} -i ${privateKeyPath}" $destinationUser@$destinationIP:$destinationDbBackupPath/DB-20220422-125355.zip .
getType(){
    read -p 'Which do you intend to restore? (db or files or both) ' restoreType

    if [ $restoreType = db -o $restoreType = files -o $restoreType = both ]
        then
            getBackupFileNames $restoreType
    else
        getType        
    fi
    
}

getBackupFileNames(){

    local rt=$1

    case $rt in

        db)
            read -p "Please enter the name of the database backup file: " dbfilename
            if [ -z $dbfilename  ]
                then
                    getBackupFileNames $restoreType
            else
                downloadRestoreDB       
            fi
            ;;

        files)
            read -p "Please enter the name of the files backup file: " filesfilename
            if [ -z $filesfilename  ]
                then
                    getBackupFileNames $restoreType
            else
                downloadRestoreFiles     
            fi
            ;;

        both)
            read -p "Please enter the name of the database backup file: " dbfilename
            read -p "Please enter the name of the files backup file: " filesfilename
            if [ -z $dbfilename -o -z $filesfilename ]
                then
                    getBackupFileNames $restoreType
            else
                downloadRestoreBoth      
            fi
            ;;

        *)
            echo -n "unknown"
            ;;
    esac
}

downloadRestoreDB(){
    read -p "Do you just download or do you want to download and restore? (d or r) " dr
    case $dr in

        d)
            downloadFiles $destinationDbBackupPath/$dbfilename
            echo "Your file has been downloaded in folder ${DownloadedBackup}"
        ;;

        r)
            downloadFiles $destinationDbBackupPath/$dbfilename
            echo "Your file has been downloaded in folder ${DownloadedBackup}"
            unzip ./$DownloadedBackup/$dbfilename -d ./$DownloadedBackup
            find ./$DownloadedBackup/DB -type f -name "*.sql"|xargs wp db import --path=$wpPath

        ;;
        *)
            downloadRestoreDB
        ;;
    esac    
}

downloadRestoreFiles(){
    read -p "Do you just download or do you want to download and restore? (d or r) " dr
    case $dr in

        d)
            downloadFiles $destinationFilesBackupPath/$filesfilename
            echo "Your file has been downloaded in folder ${DownloadedBackup}"
        ;;

        r)
            downloadFiles $destinationFilesBackupPath/$filesfilename
            echo "Your file has been downloaded in folder ${DownloadedBackup}"
            unzip ./$DownloadedBackup/$filesfilename -d ./$DownloadedBackup
            cp -Rv ./$DownloadedBackup/Files/* $wpPath
            echo "The files restored successfully."
        ;;
        *)
            downloadRestoreFiles
        ;;
    esac    
}

downloadRestoreBoth(){
    read -p "Do you just download or do you want to download and restore? (d or r) " dr
    case $dr in

        d)
            downloadFiles $destinationDbBackupPath/$dbfilename
            downloadFiles $destinationFilesBackupPath/$filesfilename
            echo "Your file has been downloaded in folder ${DownloadedBackup}"
        ;;

        r)
            downloadFiles $destinationDbBackupPath/$dbfilename
            echo "Your file has been downloaded in folder ${DownloadedBackup}"
            unzip ./$DownloadedBackup/$dbfilename -d ./$DownloadedBackup
            find ./$DownloadedBackup/DB -type f -name "*.sql"|xargs wp db import --path=$wpPath

            downloadFiles $destinationFilesBackupPath/$filesfilename
            echo "Your file has been downloaded in folder ${DownloadedBackup}"
            unzip ./$DownloadedBackup/$filesfilename -d ./$DownloadedBackup
            cp -Rv ./$DownloadedBackup/Files/* $wpPath
            echo "The files restored successfully."
        ;;
        *)
            downloadRestoreBoth
        ;;
    esac    
}


downloadFiles(){
    local destinationBackupPath=$1
    rsync -azvrh --progress -e "ssh -p ${destinationPort} -i ${privateKeyPath}" $destinationUser@$destinationIP:$destinationBackupPath ./$DownloadedBackup
}

getType

