#!/bin/bash

ROOT_DIR="/srv/samba/sign"
SRC_DIR="$ROOT_DIR/_SignIn"
TMP_DIR="/$ROOT_DIR/_SignOut/InProgress"
WAITING_LIST="$TMP_DIR/waiting.list"


waitfile() {
    while true; do
        sleep 1
        if ! [ "$(find $SRC_DIR -type f -print | wc -l)" = "0" ]; then
            process
        fi
    done
}

process () {
	local found_files=""
	local found_files=$(find $SRC_DIR -type f -printf "%f\n")
	while IFS= read -r LINE; do
		if ! grep -q "$LINE" $WAITING_LIST;then
			echo $LINE >> $WAITING_LIST
		fi
	done <<< "$found_files"

}

waitfile
