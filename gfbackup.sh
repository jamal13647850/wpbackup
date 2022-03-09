SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
DIR=`date +"%Y%m%d-%H%M%S"`
gfBackupFolder=$SCRIPTPATH/forms-$DIR
gfBackupFolderExported=$SCRIPTPATH/forms-$DIR/exported-$DIR
gfBackupFolderDB=$SCRIPTPATH/forms-$DIR/dbbackup-$DIR

#Change it
wppath='/var/www/html/visamondial'

mkdir -pv $gfBackupFolderExported
mkdir -pv $gfBackupFolderDB
cd $gfBackupFolderDB
wp db export --add-drop-table --path=$wppath

exportForms () {
  declare -A dates
  declare -A startDate
  declare -A endDate

  formid=$1
  wppath=$2

  #Change it
  input_start=21-1-1
 


  sdate=$(date -I -d "$input_start") || exit -1
  edate=`date +"%Y-%m-%d"`   || exit -1

  d="$sdate"
  counter=0
  while [[ "$d" < "$edate" ]]; do

    startDate[$counter]=$(echo $d| sed 's/20//g');

    d=$(date -I -d "$d + 30 day")
    endDate[$counter]=$(echo $d| sed 's/20//g');
    if [[ "$d" > "$edate" ]] || [[ "$d" = "$edate" ]]
    then
      endDate[$counter]=$(echo $edate| sed 's/20//g');
    fi
    d=$(date -I -d "$d + 1 day")

    dates[$counter]="--start_date=${startDate[$counter]} --end_date=${endDate[$counter]}"

    counter=$(($counter+1))
  done

  mkdir $formid
  cd $formid
  for (( j=0; j<${#dates[@]} ;j++ ));
  do
    wp gf entry export $formid  $formid-"${startDate[$j]}-${endDate[$j]}".xls --format=xls --start_date=${startDate[$j]} --end_date=${endDate[$j]} --path=$wppath
  done
}
export -f exportForms






cd $gfBackupFolderExported



wp gf form list --active --sort_column=id --path=$wppath| awk '/^[0-9]+/{print $1}' |xargs -I formid bash -c 'exportForms formid '${wppath}' &&  wp gf entry delete $(wp gf entry list formid --page_size=10000 --format=ids --path=$wppath) --force --path=$wppath'

wp gf form list --active --sort_column=id --format=csv --path=$wppath|awk '{ FS = "," } ;{print "ID: "$1" => Name: "$2}' >formlist.txt
cd ..
zip -r9 exported-$DIR.zip exported-$DIR
rm -rv exported-$DIR
