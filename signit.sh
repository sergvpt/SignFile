#!/bin/bash

# set variables
ROOTDIR="/srv/samba/sign"
SRCDIR="$ROOTDIR/_SignIn"
TMPDIR="/$ROOTDIR/_SignOut/InProgress"
DSTDIR="$ROOTDIR/_SignOut"
LOGDIR="/var/log/signit"
PIN=""
CERT="pkcs11:model=Rutoken%20ECP;manufacturer=Aktiv%20Co.;serial=<SERIAL_NUMBER_HERE>;token=Rutoken%20ECP%20%3Cno%20label%3E;id=<ID_HERE>;object=<OBJECT_HERE>;type=cert"
KEY="pkcs11:model=Rutoken%20ECP;manufacturer=Aktiv%20Co.;serial=<SERIAL_NUMBER_HERE>;token=Rutoken%20ECP%20%3Cno%20label%3E;id=<ID_HERE>;object=RSA;type=private;pin-value=$PIN"
CACERT="/etc/ssl/certs/CA-root-mid.cer"
TSACERT="/etc/ssl/certs/TSA-root-mid.cer"
WINDOMAIN="domainname"
WINUSER="username"
WINPASS="userpass"
AVSRV="0.0.0.0"
WAITING_LIST="$TMPDIR/waiting.list"

# waiting file to sign
waitfile() {
	while true; do
		sleep 3
		if [ -s $WAITING_LIST ]; then
			process
		fi
	done
}

# main process
process() {
	sleep 3
	# log rotation
	LOGRM=$(ls -t $LOGDIR/* | tail -n +20)
	for log in $LOGRM; do
		rm -f "$log"
	done

	# create log file
	if ! [ -z $LOGFILE ] && [ -f $LOGFILE ];then
		LOGFILEDATE=$(stat -c %w $LOGFILE)
		if ! [ "${LOGFILEDATE:0:10}" = "$(date +'%Y-%m-%d')" ];then
			LOGFILE="$LOGDIR/log-$(date +'%Y-%m-%d').log"
			echo "LOG FILE. DATE $(date +'%Y-%m-%d')" > $LOGFILE
		fi
	else
		LOGFILE="$LOGDIR/log-$(date +'%Y-%m-%d').log"
	fi
	echo -e "\n\n\n===============================================" >> $LOGFILE
	echo "$(date +'%Y-%m-%d-%H-%M-%S') Обнаружены файлы" >> $LOGFILE
	echo -e "===============================================\n" >> $LOGFILE
	FOUNDFILES=$(head -n 1 $WAITING_LIST)
	echo -e "$FOUNDFILES \n" >> $LOGFILE

	# check certificate expiration date
	chkcerts

	# check directories exist
	if ! [ -d $DSTDIR ];then
		mkdir -p $DSTDIR
	fi

	if ! [ -d $TMPDIR ];then
		mkdir -p $TMPDIR
	fi

	# if copied then move
	for FILE in $FOUNDFILES; do
		if [ -f $SRCDIR/$FILE ];then
			mkdir -p `dirname $TMPDIR/$FILE`
			while true; do
				mv $SRCDIR/$FILE $TMPDIR/$FILE && break
				sleep 3
			done
			# first antivirus check
			STOPFLAG=""
			avcheck "$FILE" NotSigned
			windfcheck "$FILE" NotSigned
			
			# sign
			sign "$FILE"
			
			# second antivirus check
			avcheck "$FILE" Signed
			windfcheck "$FILE" Signed
			mvtoout "$FILE"
			find $TMPDIR/* ! -name waiting.list -delete
		fi
		sed -i "\|$FOUNDFILES|d" $WAITING_LIST
	done
	
	# remove user's directories
	for FILE in $FOUNDFILES; do
		while true;do
			if [[ "$FILE" == *\/* ]] && [[ "$FILE" != *win* ]];then
				FILE=$(echo $FILE | sed 's:/[^/]*$::')
				if ! [[ "$FILE" == *\/* ]];then
					if [ "$(find $SRCDIR/$FILE -type f -print | wc -l)" = "0" ];then
						rm -f -r $SRCDIR/$FILE
						break
					else
						break
					fi
				fi
			else
				break
			fi
		done
	done
}

# sign function
sign() {
  if ! [ "$STOPFLAG" = "STOP" ];then
	while true; do
		echo "$(date +'%Y-%m-%d-%H-%M-%S') Подписание файла $1" >> $LOGFILE
		osslsigncode sign \
			-pkcs11engine /usr/lib/x86_64-linux-gnu/engines-3/pkcs11.so \
			-pkcs11module /usr/lib/librtpkcs11ecp.so \
			-key "$KEY" \
			-pkcs11cert "$CERT" \
			-in $TMPDIR/$1 \
			-out $TMPDIR/$1.signed \
			-h sha256 \
			-n "$(basename $TMPDIR/$1)" \
			-ts http://timestamp.globalsign.com/tsa/r6advanced1 >> $LOGFILE
		echo "$(date +'%Y-%m-%d-%H-%M-%S') Файл подписан. Проверка подписи." >> $LOGFILE
		if $(osslsigncode verify -CAfile $CACERT -TSA-CAfile $TSACERT -in $TMPDIR/$1.signed | grep -q Succeeded); then
			echo "$(date +'%Y-%m-%d-%H-%M-%S') Проврка подписи прошла успешно." >> $LOGFILE
			mv -f $TMPDIR/$1.signed $TMPDIR/$1
			break
		else
			echo "$(date +'%Y-%m-%d-%H-%M-%S') ВНИМАНИЕ! Проверка подписи файла завершилась с ошибкой" >> $LOGFILE
			mv -f $TMPDIR/$1 $TMPDIR/$1.NotSigned
			mvtoout "$1.NotSigned"
			STOPFLAG="STOP"
			break
		fi
	done
  fi
}

# certificate expiration date check function
chkcerts() {
	# root cert
	echo "$(date +'%Y-%m-%d-%H-%M-%S') Проверка сроков действия сертификатов" >> $LOGFILE
	if ! openssl x509 -checkend 1728000 -noout -in /etc/ssl/certs/CA-root-mid.cer; then
		mkdir -p "$DSTDIR/ПРЕДУПРЕЖДЕНИЕ-скоро-истекает-корневой-проверочный-сертификат"
		mkdir -p "$SRCDIR/ПРЕДУПРЕЖДЕНИЕ-скоро-истекает-корневой-проверочный-сертификат"
		echo "$(date +'%Y-%m-%d-%H-%M-%S') ВНИМАНИЕ! Корневой сертификат для проверки подписи истекает $(openssl x509 -enddate -noout -in /etc/ssl/certs/CA-root-mid.cer | sed 's/^.*=//'), менее чем через 20 дней, необходимо загрузить новый" >> $LOGFILE
	fi
	# timestamp cert
	if ! openssl x509 -checkend 1728000 -noout -in /etc/ssl/certs/TSA-root-mid.cer; then
		mkdir -p "$DSTDIR/ПРЕДУПРЕЖДЕНИЕ-скоро-истекает-сертификат-поверки-штампа-времени"
		mkdir -p "$SRCDIR/ПРЕДУПРЕЖДЕНИЕ-скоро-истекает-сертификат-поверки-штампа-времени"
		echo "$(date +'%Y-%m-%d-%H-%M-%S') ВНИМАНИЕ! Cертификат для проверки штампа времени истекает $(openssl x509 -enddate -noout -in /etc/ssl/certs/TSA-root-mid.cer | sed 's/^.*=//'), менее чем через 20 дней,  необходимо загрузить новый" >> $LOGFILE
	fi
	# signing cert
	expdate=$(p11tool --provider /usr/lib/librtpkcs11ecp.so --info "pkcs11:model=Rutoken%20ECP;manufacturer=Aktiv%20Co.;serial=<SERIAL_NUMBER_HERE>;token=Rutoken%20ECP%20%3Cno%20label%3E;id=<ID_HERE>;object=<OBJECT_HERE>;type=cert" | grep Expires: | sed 's/^.*: //')
	epoch1=$(date -d "$expdate -20 days" +%s)
	today=$(date +"%a %b %d %H:%M:%S %Y")
	epoch2=$(date -d "$today" +%s)
	if [ "$epoch1" -lt "$epoch2" ]; then
		mkdir -p "$DSTDIR/ПРЕДУПРЕЖДЕНИЕ-скоро-истекает-сертификат-подписи"
		mkdir -p "$SRCDIR/ПРЕДУПРЕЖДЕНИЕ-скоро-истекает-сертификат-подписи"
		echo "$(date +'%Y-%m-%d-%H-%M-%S') ВНИМАНИЕ! Сертификат для подписи файлов истекает $expdate, менее чем через 20 дней, необходимо выпустить новый" >> $LOGFILE
	fi
	echo "$(date +'%Y-%m-%d-%H-%M-%S') Завершена проверка сертификатов" >> $LOGFILE
}

# kaspersky check
avcheck() {
	if ! [ "$STOPFLAG" = "STOP" ];then
		AVCHKRESULT=""
		AVOK=""
		AVCHK=""
		AVCHKRESULT=$(ssh $WINUSER@$AVSRV "chcp 65001 & net use /Persistent:No s: \\\\SERVERNAME\\SignFolder\\_SignOut\\InProgress /user:$WINDOMAIN\\$WINUSER $WINPASS && avp.com SCAN /i0 \"S:\\$1\"")
		echo -e "\n=====KASPERSKY===== \n$AVCHKRESULT \n==================== \n" >> $LOGFILE
		AVOK=$(echo "$AVCHKRESULT" | awk -F: '/Total OK/ {print $2/1}')
		AVCHK=$(echo "$AVCHKRESULT" | awk -F: '/Processed objects/ {print $2/1}')
		if ! [ "$AVCHK" = "0" ];then
			if [ "$AVCHK" = "$AVOK" ];then
				echo "$(date +'%Y-%m-%d-%H-%M-%S') Проверка файла $1 на вирусы антивирусом Касперский на этапе $2 пройдена успешно." >> $LOGFILE
			else
				echo "$(date +'%Y-%m-%d-%H-%M-%S') ВНИМАНИЕ! При проверке файла $1 на этапе $2 антивирус Касперский вернул ответ ОБНАРУЖЕНА УГРОЗА!" >> $LOGFILE
				mv -f $TMPDIR/$1 $TMPDIR/$1.Virus.$2
				echo "File $1 checked by Kaspersky" > $TMPDIR/$1.Virus.$2.log
				echo "$AVCHKRESULT" >> $TMPDIR/$1.Virus.$2.log
				mvtoout "$1.Virus.$2"
				mvtoout "$1.Virus.$2.log"
				STOPFLAG="STOP"
			fi
		else
			echo "$(date +'%Y-%m-%d-%H-%M-%S') ВНИМАНИЕ! При проверке файла $1 на этапе $2 антивирус Касперский не проверил ни один файл. Что-то не так." >> $LOGFILE
			mv -f $TMPDIR/$1 $TMPDIR/$1.NotCheckedForVirus.$2
			echo "File $1 checked by Kaspersky" > $1.NotCheckedForVirus.$2.log
			echo "$AVCHKRESULT" >> $TMPDIR/$1.NotCheckedForVirus.$2.log
			mvtoout "$1.NotCheckedForVirus.$2"
			mvtoout "$1.NotCheckedForVirus.$2.log"
			STOPFLAG="STOP"
		fi
	fi
}

# windows defender check
windfcheck() {
	if ! [ "$STOPFLAG" = "STOP" ];then
		AVCHKRESULT=""
		AVOK=""
		AVCHK=""
		AVCHKRESULT=$(ssh $WINUSER@$AVSRV "chcp 65001 & net use /Persistent:No s: \\\\SERVERNAME\\SignFolder\\_SignOut\\InProgress /user:$WINDOMAIN\\$WINUSER $WINPASS && \"%ProgramFiles%\Windows Defender\MpCmdRun.exe\" -Scan -ScanType 3 -File \"S:\\$1\" -DisableRemediation")
		echo -e "\n=====WINDOWS DEFENDER===== \n$AVCHKRESULT \n========================== \n" >> $LOGFILE
		AVOK=$(echo "$AVCHKRESULT" | grep "DETECTED")
		AVCHK=$(echo "$AVCHKRESULT" | grep "Failed")
		if [ -z "$AVCHK" ];then
			if [ -z "$AVOK" ];then
				echo "$(date +'%Y-%m-%d-%H-%M-%S') Проверка файла $1 на вирусы антивирусом MS Windows Defender на этапе $2 пройдена успешно." >> $LOGFILE
			else
				echo "$(date +'%Y-%m-%d-%H-%M-%S') ВНИМАНИЕ! При проверке файла $1 на этапе $2 антивирус MS Windows Defender вернул ответ ОБНАРУЖЕНА УГРОЗА!" >> $LOGFILE
				mv -f $TMPDIR/$1 $TMPDIR/$1.Virus.$2
				echo "File $1 checked by MS Windows Defender" > $TMPDIR/$1.Virus.$2.log
				echo "$AVCHKRESULT" >> $TMPDIR/$1.Virus.$2.log
				mvtoout "$1.Virus.$2"
				mvtoout "$1.Virus.$2.log"
				STOPFLAG="STOP"
			fi
		else
			echo "$(date +'%Y-%m-%d-%H-%M-%S') ВНИМАНИЕ! При проверке файла $1 на этапе $2 антивирус MS Windows Defender не проверил ни один файл. Что-то не так." >> $LOGFILE
			mv -f $TMPDIR/$1 $TMPDIR/$1.NotCheckedForVirus.$2
			echo "File $1 checked by MS Windows Defender" > $1.NotCheckedForVirus.$2.log
			echo "$AVCHKRESULT" >> $TMPDIR/$1.NotCheckedForVirus.$2.log
			mvtoout "$1.NotCheckedForVirus.$2"
			mvtoout "$1.NotCheckedForVirus.$2.log"
			STOPFLAG="STOP"
		fi
	fi
}

# move file to dst directory
mvtoout() {
	if ! [ "$STOPFLAG" = "STOP" ];then
	  mkdir -p `dirname $DSTDIR/$1`
	  mv -f $TMPDIR/$1 $DSTDIR/$1 && echo "$(date +'%Y-%m-%d-%H-%M-%S') Файл $1 перемещён в каталог SignOut" >> $LOGFILE
	fi
}

# run the script
waitfile
