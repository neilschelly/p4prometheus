#!/bin/bash
# aws_report_instance_data.sh
# 
# Collects basic AWS metadata about a customer environment.
#
# If used, put this job into perforce user crontab:
#
#   10 0 * * * /p4/common/site/bin/aws_report_instance_data.sh -c /p4/common/config/.push_metrics.cfg > /dev/null 2>&1 ||:
#
# You can specify a config file as above, with expected format the same as for push_metrics.sh
#
# Uses AWS metadata URLs as defined: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instancedata-data-retrieval.html
#
# Please note you need to make sure that the specified directory below (which may be linked)
# can be read by the node_exporter user (and is setup via --collector.textfile.directory parameter)
#

# ============================================================
# Configuration section

declare Log="/p4/1/logs/report_instance_data.log"

# This might also be /hxlogs/metrics or passed as a parameter (with -m flag)
declare metrics_root=/p4/metrics

# Default to AWS
declare -i IsAWS=1
declare -i IsAzure=0

# ============================================================

declare ThisScript=${0##*/}

function msg () { echo -e "$*"; }
function log () { dt=$(date '+%Y-%m-%d %H:%M:%S'); echo -e "$dt: $*" >> "$Log"; msg "$dt: $*"; }
function bail () { msg "\nError: ${1:-Unknown Error}\n"; exit ${2:-1}; }

touch "$Log" || bail "Could not start logging; aborting."

function usage
{
   declare style=${1:--h}
   declare errorMessage=${2:-Unset}
 
   if [[ "$errorMessage" != Unset ]]; then
      echo -e "\\n\\nUsage Error:\\n\\n$errorMessage\\n\\n" >&2
   fi
 
   echo "USAGE for $ThisScript:
 
$ThisScript -c <config_file> [-m <metrics_root>] [-aws|-azure]
 
   or
 
$ThisScript -h

    <metrics_root> is the directory where metrics are being written - default: $metrics_root
    -azure      Specifies to collect Azure specific data (default is AWS)

Collects metadata about the current instance and pushes the data centrally.

This is not normally required on customer machines. It assumes an SDP setup.
"
}

# Command Line Processing
 
declare -i shiftArgs=0
ConfigFile=/p4/common/config/.push_metrics.cfg

set +u
while [[ $# -gt 0 ]]; do
    case $1 in
        (-h) usage -h && exit 0;;
        # (-man) usage -man;;
        (-c) ConfigFile=$2; shiftArgs=1;;
        (-m) metrics_root=$2; shiftArgs=1;;
        (-azure) IsAWS=0; IsAzure=1;;
        (-*) usage -h "Unknown command line option ($1)." && exit 1;;
    esac
 
    # Shift (modify $#) the appropriate number of times.
    shift; while [[ "$shiftArgs" -gt 0 ]]; do
        [[ $# -eq 0 ]] && usage -h "Incorrect number of arguments."
        shiftArgs=$shiftArgs-1
        shift
    done
done
set -u

[[ -f "$ConfigFile" ]] || bail "Can't find config file: ${ConfigFile}!"

# Get config values - format: key=value
metrics_host=$(grep metrics_host "$ConfigFile" | awk -F= '{print $2}')
metrics_customer=$(grep metrics_customer "$ConfigFile" | awk -F= '{print $2}')
metrics_instance=$(grep metrics_instance "$ConfigFile" | awk -F= '{print $2}')
metrics_user=$(grep metrics_user "$ConfigFile" | awk -F= '{print $2}')
metrics_passwd=$(grep metrics_passwd "$ConfigFile" | awk -F= '{print $2}')

metrics_host=${metrics_host:-Unset}
metrics_customer=${metrics_customer:-Unset}
metrics_instance=${metrics_instance:-Unset}
metrics_user=${metrics_user:-Unset}
metrics_passwd=${metrics_passwd:-Unset}
metadata_logfile=${metadata_logfile:-/p4/1/logs/report_instance_data.log}
if [[ $metrics_host == Unset || $metrics_user == Unset || $metrics_passwd == Unset || $metrics_customer == Unset || $metrics_instance == Unset ]]; then
   echo -e "\\nError: Required parameters not supplied.\\n"
   echo "You must set the variables metrics_host, metrics_user, metrics_passwd, metrics_customer, metrics_instance in $ConfigFile."
   exit 1
fi

# Convert host from 9091 -> 9092 (pushgateway -> datapushgateway default)
metrics_host=${metrics_host/91$/92}

# Collect various metrics

TempLog="$metrics_root/_instance_data.log"

# For AWS:
# curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/dynamic/instance-identity/document
# {
#   "accountId" : "251689412290",
#   "architecture" : "x86_64",
#   "availabilityZone" : "us-east-1a",
#   "billingProducts" : null,
#   "devpayProductCodes" : null,
#   "marketplaceProductCodes" : null,
#   "imageId" : "ami-047261a33f6dcc468",
#   "instanceId" : "i-0fce0e35c7b971d6a",
#   "instanceType" : "c5.18xlarge",
#   "kernelId" : null,
#   "pendingTime" : "2022-05-22T05:08:09Z",
#   "privateIp" : "10.0.0.239",
#   "ramdiskId" : null,
#   "region" : "us-east-1",
#   "version" : "2017-09-30"
# }

hostnamectl > $TempLog 2>&1

if [[ $IsAWS -eq 1 ]]; then
    TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
    Doc=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/dynamic/instance-identity/document)
    echo "$Doc" >> $TempLog
fi

if [[ $IsAzure -eq 1 ]]; then
    Doc=$(curl -s -H Metadata:true --noproxy "*" "http://169.254.169.254/metadata/instance?api-version=2021-02-01" | python -m json.tool)
    echo "$Doc" >> $TempLog
fi

# Loop while pushing as there seem to be temporary password failures quite frequently

iterations=0
max_iterations=10
STATUS=1
while [ $STATUS -ne 0 ]; do
    sleep 1
    ((iterations=$iterations+1))
    log "Pushing metrics"
    result=$(curl --retry 5 --user "$metrics_user:$metrics_passwd" --data-binary "@$TempLog" "$metrics_host/data/?customer=$metrics_customer&instance=$metrics_instance")
    STATUS=0
    log "Checking result: $result"
    if [[ "$result" = '{"message":"invalid username or password"}' ]]; then
        STATUS=1
        log "Retrying due to temporary password failure"
    fi
    if [ "$iterations" -ge "$max_iterations" ]; then
        log "Push loop iterations exceeded"
        exit 1
    fi
done