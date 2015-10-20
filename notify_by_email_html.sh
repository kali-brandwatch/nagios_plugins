#!/bin/bash

##
## By kali
## Build html notification to be piped to mail command
##
##

## General variables and default values

PROGRAM_BASEDIR="/srv/icinga"
TEMPLATES_DIR="${PROGRAM_BASEDIR}/notifications_templates"
OUTPUT_ARCHIVE_DIR="${PROGRAM_BASEDIR}/var/spool/notifications_output"
FROM_EMAIL="no-reply@your-domain.com"
IMG_WIDTH=500
IMG_HEIGHT=200
ATTACHMENT_ID=0

declare -a IMG_ATTACHMENTS

# Merge macro env variables to work seamlessly with nagios or icinga1
MACRO_HOSTADDRESS="${NAGIOS_HOSTADDRESS}${ICINGA_HOSTADDRESS}"
MACRO_HOSTALIAS="${NAGIOS_HOSTALIAS}${ICINGA_HOSTALIAS}"
MACRO_HOSTDURATION="${NAGIOS_HOSTDURATION}${ICINGA_HOSTDURATION}"
MACRO_HOSTNAME="${NAGIOS_HOSTNAME}${ICINGA_HOSTNAME}"
MACRO_HOSTNOTIFICATIONNUMBER="${NAGIOS_HOSTNOTIFICATIONNUMBER}${ICINGA_HOSTNOTIFICATIONNUMBER}"
MACRO_HOSTOUTPUT="${NAGIOS_HOSTOUTPUT}${ICINGA_HOSTOUTPUT}"
MACRO_HOSTSTATE="${NAGIOS_HOSTSTATE}${ICINGA_HOSTSTATE}"
MACRO_LASTSERVICESTATE="${NAGIOS_LASTSERVICESTATE}${ICINGA_LASTSERVICESTATE}"
MACRO_LONGDATETIME="${NAGIOS_LONGDATETIME}${ICINGA_LONGDATETIME}"
MACRO_LONGHOSTOUTPUT="${NAGIOS_LONGHOSTOUTPUT}${ICINGA_LONGHOSTOUTPUT}"
MACRO_LONGSERVICEOUTPUT="${NAGIOS_LONGSERVICEOUTPUT}${ICINGA_LONGSERVICEOUTPUT}"
MACRO_NOTIFICATIONAUTHOR="${NAGIOS_NOTIFICATIONAUTHOR}${ICINGA_NOTIFICATIONAUTHOR}"
MACRO_NOTIFICATIONCOMMENT="${NAGIOS_NOTIFICATIONCOMMENT}${ICINGA_NOTIFICATIONCOMMENT}"
MACRO_NOTIFICATIONTYPE="${NAGIOS_NOTIFICATIONTYPE}${ICINGA_NOTIFICATIONTYPE}"
MACRO_SERVICECHECKCOMMAND="${NAGIOS_SERVICECHECKCOMMAND}${ICINGA_SERVICECHECKCOMMAND}"
MACRO_SERVICEDESC="${NAGIOS_SERVICEDESC}${ICINGA_SERVICEDESC}"
MACRO_SERVICEDURATION="${NAGIOS_SERVICEDURATION}${ICINGA_SERVICEDURATION}"
MACRO_SERVICENOTIFICATIONNUMBER="${NAGIOS_SERVICENOTIFICATIONNUMBER}${ICINGA_SERVICENOTIFICATIONNUMBER}"
MACRO_SERVICEOUTPUT="${NAGIOS_SERVICEOUTPUT}${ICINGA_SERVICEOUTPUT}"
MACRO_SERVICESTATE="${NAGIOS_SERVICESTATE}${ICINGA_SERVICESTATE}"
# You should add here any custom macro you wish to use
MACRO__SERVICEASSOCIATED_DASHBOARD="${NAGIOS__SERVICEASSOCIATED_DASHBOARD}${ICINGA__SERVICEASSOCIATED_DASHBOARD}"
MACRO__SERVICEASSOCIATED_GRAPHITE="${NAGIOS__SERVICEASSOCIATED_GRAPHITE}${ICINGA__SERVICEASSOCIATED_GRAPHITE}"
MACRO__SERVICENOTIFICATIONS_MUTE="${NAGIOS__SERVICENOTIFICATIONS_MUTE}${ICINGA__SERVICENOTIFICATIONS_MUTE}"
MACRO__SERVICENOTIFICATION_TEMPLATE="${NAGIOS__SERVICENOTIFICATION_TEMPLATE}${ICINGA__SERVICENOTIFICATION_TEMPLATE}"

# default needed curl options - allow special chars + silent + timeout 10 seconds
CURL_OPTIONS="-g -s --max-time 10"

declare -A COLORS_NOTIFICATION
COLORS_NOTIFICATION[OK]='#88d066'
COLORS_NOTIFICATION[WARNING]='#ffff00'
COLORS_NOTIFICATION[CRITICAL]='#f88888'
COLORS_NOTIFICATION[UNKNOWN]='#ffbb55'
COLORS_NOTIFICATION[UP]='#88d066'
COLORS_NOTIFICATION[DOWN]='#f88888'

declare -a COLORS_TABLE
COLORS_TABLE[0]='#f4f4f4'
COLORS_TABLE[1]='#e7e7e7'

declare -A NOTIFICATIONS_MUTE
NOTIFICATIONS_MUTE[OK]="o"
NOTIFICATIONS_MUTE[WARNING]="w"
NOTIFICATIONS_MUTE[CRITICAL]="c"
NOTIFICATIONS_MUTE[UNKNOWN]="u"

## Get parameters

while (( "$#" )); do
	case "$1" in
		-m|--mail)
			EMAIL_TARGET="$2"
			shift
		;;
		-t|--type)
			case ${2,,} in
				host|h)
					NOTIFICATION_TYPE="HOST"
				;;
				*)	# assume default notification is for service
					NOTIFICATION_TYPE="SERVICE"
				;;
			esac
			shift
		;;
		-n|--nagios_url)
			PROGRAM_BASEURL="${2}"
			shift
		;;
		-N|--nagios_auth)
			CURL_OPTIONS_NAGIOS="${CURL_OPTIONS} -k -u ${2}"
			shift
		;;
		-g|--graphite_url_link)
			GRAPHITE_BASEURL_LINK="${2}/render/?width=${IMG_WIDTH}&height=${IMG_HEIGHT}&target="
			shift
		;;
		--graphite_url_embed)
			GRAPHITE_BASEURL_EMBED="${2}/render/?width=${IMG_WIDTH}&height=${IMG_HEIGHT}&target="
			shift
		;;
		-G|--graphite_auth)
			CURL_OPTIONS_GRAPHITE="${CURL_OPTIONS} -k -u ${2}"
			shift
		;;
		--graphitus_url)
			GRAPHITUS_BASEURL="${2}/dashboard.html?id="
			shift
		;;
		--from_email)
			FROM_EMAIL="${2}"
			shift
		;;
		-d|--debug)
			set -x
		;;
		*)
			# silently ignore unknown parameters rather than rant about it and exit
		;;
	esac
	shift
done

## Check for new mute parameter
if [ "${MACRO__SERVICENOTIFICATIONS_MUTE}" != "" ] && [ "${NOTIFICATION_TYPE}-${MACRO_NOTIFICATIONTYPE}" == "SERVICE-PROBLEM" ] && [[ ${MACRO__SERVICENOTIFICATIONS_MUTE} == *${NOTIFICATIONS_MUTE[${MACRO_SERVICESTATE}]}* ]] && [ "${MACRO_SERVICESTATE}" == "${MACRO_LASTSERVICESTATE}" ] && [ ${MACRO_SERVICENOTIFICATIONNUMBER} -gt 1 ] ; then
	exit 0
fi

# Get last and new check output, and store the new one
MACRO_LAST_SERVICE_OUTPUT=$(cat ${OUTPUT_ARCHIVE_DIR}/${MACRO_HOSTALIAS}.${MACRO_SERVICEDESC}.out 2>/dev/null)
MACRO_COMPLETE_SERVICE_OUTPUT="${MACRO_SERVICEOUTPUT} ${MACRO_LONGSERVICEOUTPUT}"
[ -d ${OUTPUT_ARCHIVE_DIR} ] || mkdir -p ${OUTPUT_ARCHIVE_DIR}/
echo $MACRO_COMPLETE_SERVICE_OUTPUT > ${OUTPUT_ARCHIVE_DIR}/${MACRO_HOSTALIAS}.${MACRO_SERVICEDESC}.out

# Store affected metrics. Works only with outputs like those produced by check_graphite
LAST_AFFECTED_METRICS=$(sed 's/\(OK\|CRITICAL\|UNKNOWN\) - //; s/=[^:space:]*[:space:]/,/g; s/,$//' <<< ${MACRO_LAST_SERVICE_OUTPUT})
NEW_AFFECTED_METRICS=$(sed 's/\(OK\|CRITICAL\|UNKNOWN\) - //; s/=[^:space:]*[:space:]/,/g; s/,$//' <<< ${MACRO_COMPLETE_SERVICE_OUTPUT})

## Build message through templates

# if a custom field for the template is provided, try to use it. otherwise use the one per notification type.
NOTIFICATION_TEMPLATE=${NOTIFICATION_TYPE,,}
if [ ! -z ${MACRO__SERVICENOTIFICATION_TEMPLATE+x} ] ; then
	[ -f $TEMPLATES_DIR/${MACRO__SERVICENOTIFICATION_TEMPLATE,,}.tpl ]	&& NOTIFICATION_TEMPLATE=${MACRO__SERVICENOTIFICATION_TEMPLATE,,}
fi
source $TEMPLATES_DIR/$NOTIFICATION_TEMPLATE.tpl

## send mail
MESSAGE_HEADER="To: ${EMAIL_TARGET}
From: ${FROM_EMAIL}
Subject: ${MESSAGE_SUBJECT}
MIME-Version: 1.0
Content-Type: multipart/related; boundary=\"related_boundary\"

--related_boundary
Content-Type: text/html; charset=\"utf-8\"
Content-Transfer-Encoding: 8bit

"

ATTACHMENT_ID=0
for img_att in "${IMG_ATTACHMENTS[@]}" ; do
	((ATTACHMENT_ID++))
	MESSAGE_FOOTER+="
--related_boundary
Content-Type: image/png; name=\"embedded_img_${ATTACHMENT_ID}.png\"
Content-Disposition: inline; filename=\"embedded_img_${ATTACHMENT_ID}.png\"
Content-Location: embedded_img_${ATTACHMENT_ID}.png
Content-ID: <embedded_img_${ATTACHMENT_ID}>
Content-Transfer-Encoding: base64

"
	MESSAGE_FOOTER+=$img_att

done

MESSAGE_FOOTER+="
--related_boundary--
"

echo -e "$MESSAGE_HEADER" "$MESSAGE_BODY" "$MESSAGE_FOOTER" | sendmail -t -f "${FROM_EMAIL}"
