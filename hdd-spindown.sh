#!/bin/bash

# hdd-spindown.sh
# ---------------
# Automatic Disk Standby Using Kernel Diskstats and hdparm
# (C) 2011-2017 Alexander Koch <mail@alexanderkoch.net>
#
# Released under the terms of the MIT License, see 'LICENSE'


# configuration file, (ba)sh-style
CONFIG="/etc/hdd-spindown.rc"

# default setting for watch interval: 300s
INTERV=${CONF_INT:-300}
# default setting for spinup read size: 128MiB
SPINUP_MB=${SPINUP_READLEN:-128}

# user presence
USER_PRESENT=0


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
	if [ $LOG_SYSLOG -eq 1 ]; then
		logger -t "hdd-spindown.sh" --id=$$ "$1"
	else
		echo "$1"
	fi
}

function selftest_active() {
	which smartctl &>/dev/null || return 0
	smartctl -a "/dev/$1" | grep -q "Self-test routine in progress"
	return $?
}

function dev_stats() {
	awk '{printf "%s|%s\n", $1, $5}' < "/sys/block/$1/stat"
}

function dev_isup() {
	hdparm -C "/dev/$1" | grep -q active
	return $?
}

function dev_spindown() {
	# skip spindown if already spun down
	dev_isup "$1" || return 0

	# omit spindown if SMART Self-Test in progress
	selftest_active "$1" && return 0

	# spindown disk
	log "suspending $1"
	hdparm -qy "/dev/$1"
	if [ $? -gt 0 ]; then
		log "failed to suspend $1"
		return 1
	fi

	return 0
}

function dev_spinup() {
	# skip spinup if already online
	dev_isup "$1" && return 0

	# read raw blocks, bypassing cache
	log "spinning up $1"
	dd if=/dev/$1 of=/dev/null bs=1M count=$SPINUP_MB iflag=direct &>/dev/null
}

function update_presence() {
	# no action if no hosts defined, match unconfigured behaviour
	[ -z "$USER_HOSTS" ] && return 0

	# assume present if any user host is ping'able
	for H in "${USER_HOSTS[@]}"; do
		if ping -c 1 -q "$H" &>/dev/null; then
			if [ $USER_PRESENT -eq 0 ]; then
				log "user now present"
				USER_PRESENT=1
			fi
			return 0
		fi
	done

	# absent
	if [ $USER_PRESENT -eq 1 ]; then
		log "user now absent"
		USER_PRESENT=0
	fi

	return 0
}

function check_dev() {
	NUM=$1

	# initialize real device name
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
	
	# initialize r/w timestamp
	[ -z "${STAMP[$NUM]}" ] && STAMP[$NUM]=$(date +%s)

	# check for user presence, spin up if required
	if [ $USER_PRESENT -eq 1 ]; then
		dev_isup "$DEV" || dev_spinup "$DEV"
	fi

	# refresh r/w stats
	COUNT_NEW="$(dev_stats "$DEV")"

	# spindown logic if stats equal previous recordings
	if [ "${COUNT[$NUM]}" == "$COUNT_NEW" ]; then
		# skip spindown if user present
		if [ $USER_PRESENT -eq 0 ]; then
			# check against idle timeout
			if [ $(($(date +%s) - ${STAMP[$NUM]})) -ge ${TIMEOUT[$NUM]} ]; then
				# spindown disk
				dev_spindown "$DEV"
			fi
		fi
	else
		# update r/w timestamp
		COUNT[$NUM]="$COUNT_NEW"
		STAMP[$NUM]=$(date +%s)
	fi
}


# parse cmdline arguments
LOG_SYSLOG=0
[ "$1" == "--syslog" ] && LOG_SYSLOG=1

# check prerequisites
check_req date awk hdparm dd
[ $LOG_SYSLOG -eq 1 ] && check_req logger

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
	update_presence
	for I in $(seq 0 $I_MAX); do
		check_dev $I
	done

	sleep $INTERV
done
