#!/bin/bash

#                            hdd-spindown.sh
#
#        Automatic Disk Standby using Kernel diskstats and hdparm
#             2011-2015 by Alexander Koch <lynix47@gmail.com>


# configuration file, (ba)sh-style
CONFIG="/etc/hdd-spindown.rc"

# default setting for watch interval: 300s
INTERV=${CONF_INT:-300}


function check_req() {
	FAIL=0
	for CMD in $@; do
		which $CMD >/dev/null && continue
		echo "error: unable to execute: '$CMD'"
		FAIL=1
	done
	[ $FAIL -ne 0 ] && exit 1
}

function log() {
	logger -t "hdd-spindown.sh" --id=$$ "$1"
}

function selftest_active() {
	smartctl -a "/dev/$1" | grep -q "Self-test routine in progress"
	return $?
}

function dev_stats() {
	awk '{printf "%s|%s\n", $1, $5}' < "/sys/block/$1/stat"
}	

function check_dev() {
	NUM=$1

	DEV="${DEVICES[$NUM]}"
	if ! [ -e "/dev/$DEV" ]; then
		if [ -L "/dev/disk/by-id/$DEV" ]; then
			DEV="$(basename "$(readlink "/dev/disk/by-id/$DEV")")"
			log "recognized disk: ${DEVICES[$NUM]} --> $DEV"
			DEVICES[$NUM]="$DEV"
		else
			log "device not found: $DEV, skipping"
			return 1
		fi
	fi
		
	[ -z "${STAMP[$NUM]}" ] && STAMP[$NUM]=$(date +%s)

	COUNT_NEW="$(dev_stats "$DEV")"
	if [ "${COUNT[$NUM]}" == "$COUNT_NEW" ]; then
		if [ $(($(date +%s) - ${STAMP[$NUM]})) -ge ${TIMEOUT[$NUM]} ]; then
			# omit spindown if SMART Self-Test in progress
			selftest_active "$DEV" && return 0
			if hdparm -C "/dev/$DEV" | grep -q active; then
				log "suspending $DEV"
				hdparm -qy "/dev/$DEV"
				if [ $? -gt 0 ]; then
					log "failed to suspend $DEV"
					return 1
				fi
			fi
		fi
	else
		COUNT[$NUM]="$COUNT_NEW"
		STAMP[$NUM]=$(date +%s)
	fi
}


# check prerequisites
check_req date awk hdparm smartctl logger

# check config file
if ! [ -r "$CONFIG" ]; then
	echo "error: unable to read config file '$CONFIG', aborting."
	exit 1
fi
source "$CONFIG"
if [ -z "$CONF_DEV" ]; then
	echo "error: missing configuration parameter 'CONFIG_DEV', aborting."
	exit 1
fi

# initialize device arrays
I_MAX=$((${#CONF_DEV[@]} - 1))
for I in $(seq 0 $I_MAX); do
	DEVICES[$I]="$(echo "${CONF_DEV[$I]}" | cut -d '|' -f 1)"
	TIMEOUT[$I]="$(echo "${CONF_DEV[$I]}" | cut -d '|' -f 2)"
done


# main loop
while true; do
	for I in $(seq 0 $I_MAX); do
		check_dev $I
	done

	sleep $INTERV
done
