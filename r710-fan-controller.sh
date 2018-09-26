#!/bin/sh

# Ist ein Megaraid controller installiert? z.B. H700 
MEGARAID=1

# Ausgabe im terminal (1=Ein / 2=Aus)
DEBUG=1

# Sekunden zwischen den Abfragen
SLEEP_TIMER=5

# Hysterese zum runterregeln der Lüfter
SLEEP_TIMER_MULTIPLY=6

# Temperatur Level der CPU
# (LEVEL0 ist alles unter LEVEL1)
CPU_LEVEL1=36
CPU_LEVEL2=42
CPU_LEVEL3=48
CPU_LEVEL4=55
CPU_LEVEL5=65

HDD_LEVEL1=36
HDD_LEVEL2=38
HDD_LEVEL3=40
HDD_LEVEL4=42
HDD_LEVEL4=44
HDD_LEVEL5=46

# Lüfter umdrehungen (Dell R710) in Hex:
# 0x09 = 2100
# 0x10 = 2800
# 0x13 = 3240
# 0x22 = 4680
# 0x32 = 6600
# 0x38 = 7440
# auto = iDrac regelt die Lüfter selbst


FAN_LEVEL0=0x09
FAN_LEVEL1=0x13
FAN_LEVEL2=0x22
FAN_LEVEL3=0x32
FAN_LEVEL4=0x38
FAN_LEVEL5=auto

# Init
OLD_LEVEL=5
FAN_IS_AUTO=1
CMD_FAN_AUTO=0
TIMER_MULTIPLY=0

# Bei Abbruch durch STRG-C regelt iDrac die Lüfter wieder
trap exit_auto INT

poll_drive_temp() {
	high_drive_temp=0
	if [ $MEGARAID -eq 1 ]; then
		for drive in 00 01 02 03 04 05 06 07; do
			if [ "`smartctl -d megaraid,$drive -a /dev/sda -a | grep SAS`" != "" ]; then
				drive_temp=`smartctl -d megaraid,$drive /dev/sdb -A | grep "Current Drive Temperature" | awk '{print $4}' | tail -n1` || drive_temp=0
			else
				drive_temp=`smartctl -d megaraid,$drive -A /dev/sdb | grep "Temperature" | awk '{print $10}' | tail -n1` || drive_temp=0
			fi

			if [ $drive_temp ]; then

				if [ $drive_temp -gt $high_drive_temp ]; then
					high_drive_temp=$drive_temp
				fi
			else
				drive_temp="nicht installiert"
			fi

			if [ $DEBUG -eq 2 ]; then
				echo "$drive: $drive_temp"
			fi
		done
	else
		for drive in `lsblk -d | grep sd | awk '{print $1}'`; do
			if [ "`smartctl -a $drive -a | grep SAS`" != "" ]; then
				drive_temp=`smartctl /dev/$drive -A | grep "Current Drive Temperature" | awk '{print $4}'` || drive_temp=0
			else
				drive_temp=`smartctl -A /dev/$drive | grep "Temperature" | awk '{print $10}' | tail -n1` || drive_temp=0
			fi

			if [ $drive_temp ]; then
				if [ $drive_temp -gt $high_drive_temp ]; then
					high_drive_temp=$drive_temp
				fi
			else
				drive_temp="nicht installiert"
			fi

			if [ $DEBUG -eq 2 ]; then
				echo "$drive Temp: $drive_temp"
			fi
		done
	fi

	if [ $DEBUG -gt 0 ]; then
		echo "Hoechste HDD Temp.: $high_drive_temp Celcius."
	fi
}

#
# Abfrage CPU Temperatur via lm_sensors coretemp
#
poll_core_temp() {
	high_core_temp=0
	for core_temp in `sensors | grep Core | awk '{print $3}' | cut -d '+' -f2 | cut -d '.' -f1`; do
		if [ $core_temp -gt $high_core_temp ]; then
			high_core_temp=$core_temp
		fi

		if [ $DEBUG -eq 2 ]; then
			echo "Core Temp: $core_temp"
			echo "High Temp: $high_core_temp"
		fi
	done

	if [ $DEBUG -gt 0 ]; then
		echo "Hoechster CPU core Temp.: $high_core_temp Celcius."
	fi
}

# Vergleiche die Temperaturen und setze das Lüfter Level
level_test() {
	if [ $high_core_temp -lt $CPU_LEVEL1 ] && [ $high_drive_temp -lt $HDD_LEVEL1 ]; then
		NEW_LEVEL=0
		if [ "$FAN_LEVEL0" = "auto" ]; then
			CMD_FAN_AUTO=1
		else
			IPMI_CMD="raw 0x30 0x30 0x02 0xff $FAN_LEVEL0"
		fi
	elif [ $high_core_temp -lt $CPU_LEVEL2 ] && [ $high_drive_temp -lt $HDD_LEVEL2 ]; then
		NEW_LEVEL=1
		if [ "$FAN_LEVEL1" = "auto" ]; then
			CMD_FAN_AUTO=1
		else
			IPMI_CMD="raw 0x30 0x30 0x02 0xff $FAN_LEVEL1"
		fi
	elif [ $high_core_temp -lt $CPU_LEVEL3 ] && [ $high_drive_temp -lt $HDD_LEVEL3 ]; then
		NEW_LEVEL=2
		if [ "$FAN_LEVEL2" = "auto" ]; then
			CMD_FAN_AUTO=1
		else
			IPMI_CMD="raw 0x30 0x30 0x02 0xff $FAN_LEVEL2"
		fi
	elif [ $high_core_temp -lt $CPU_LEVEL4 ] && [ $high_drive_temp -lt $HDD_LEVEL4 ]; then
		NEW_LEVEL=3
		if [ "$FAN_LEVEL3" = "auto" ]; then
			CMD_FAN_AUTO=1
		else
			IPMI_CMD="raw 0x30 0x30 0x02 0xff $FAN_LEVEL3"
		fi
	elif [ $high_core_temp -lt $CPU_LEVEL5 ] && [ $high_drive_temp -lt $HDD_LEVEL5 ]; then
		NEW_LEVEL=4
		if [ "$FAN_LEVEL4" = "auto" ]; then
			CMD_FAN_AUTO=1
		else
			IPMI_CMD="raw 0x30 0x30 0x02 0xff $FAN_LEVEL4"
		fi
	else
		NEW_LEVEL=5
		if [ "$FAN_LEVEL5" = "auto" ]; then
			CMD_FAN_AUTO=1
		else
			IPMI_CMD="raw 0x30 0x30 0x02 0xff $FAN_LEVEL5"
		fi
	fi
}

# Level down
level_compare() {
	if [ $OLD_LEVEL -eq $NEW_LEVEL ]; then
		if [ $DEBUG -gt 0 ]; then
			echo "Gehe zu Level: $OLD_LEVEL."
		fi
		TIMER_MULTIPLY=$SLEEP_TIMER_MULTIPLY
	elif [ $OLD_LEVEL -gt $NEW_LEVEL ] && [ $TIMER_MULTIPLY -gt 0 ]; then
		if [ $DEBUG -gt 0 ]; then
			echo "Warte $TIMER_MULTIPLY mehr Abfragen für Level down."
		fi
		TIMER_MULTIPLY=`expr $TIMER_MULTIPLY - 1`
	else
		level_change
		TIMER_MULTIPLY=$SLEEP_TIMER_MULTIPLY
	fi
}

level_change() {
	if [ $CMD_FAN_AUTO -eq 1 ] && [ $FAN_IS_AUTO -ne 1 ]; then
		if [ $DEBUG -gt 0 ]; then
			echo "Auto Modus"
		fi
		`ipmitool raw 0x30 0x30 0x01 0x01`
		FAN_IS_AUTO=1
		CMD_FAN_AUTO=0
	elif [ $CMD_FAN_AUTO -eq 1 ] && [ $FAN_IS_AUTO -eq 1 ]; then
		if [ $DEBUG -gt 0 ]; then
			echo "Auto Modus aktiv"
		fi
		CMD_FAN_AUTO=0
	elif [ $CMD_FAN_AUTO -eq 0 ] && [ $FAN_IS_AUTO -eq 1 ]; then
		if [ $DEBUG -gt 0 ]; then
			echo "Manueller Modus"
		fi
		`ipmitool raw 0x30 0x30 0x01 0x00`
		FAN_IS_AUTO=0
		CMD_FAN_AUTO=0
	else
		if [ $DEBUG -gt 0 ]; then
			echo "Manueller Modus aktiv"
		fi
	fi
	if [ $DEBUG -gt 0 ]; then
		echo "Wechsle zu Fan Level: $NEW_LEVEL."
	fi
	`ipmitool $IPMI_CMD`
	OLD_LEVEL=$NEW_LEVEL
}


exit_auto() {
        echo "Exit."
        echo "iDrac Kontrolle."
        `ipmitool raw 0x30 0x30 0x01 0x01`
        exit 0
}

# Script Loop
while true; do
	if [ $DEBUG -gt 0 ]; then
		echo "Starte Abfrage..."
	fi
	poll_core_temp
	poll_drive_temp
	level_test
	level_compare
	if [ $DEBUG -gt 0 ]; then
		echo "Warte $SLEEP_TIMER Sekunden..."
		echo
	fi
	sleep $SLEEP_TIMER
done

exit 0
