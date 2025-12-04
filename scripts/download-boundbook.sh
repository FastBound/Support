#!/bin/bash
#
# Download a single, compliant A&D bound book from a single FastBound account.
#
# A simple script to download a single, compliant A&D bound book from a single
# FastBound account per ATF Ruling 2016-1.
#
# SECURITY WARNING: This script requires your API key to be passed as a command-line
# argument. On multi-user systems, command-line arguments are visible to all users
# via process listing tools (e.g., ps). If you schedule this script as a task on a
# shared system, other users may be able to see your API key.
#
# https://fastb.co/DownloadFastBoundBook carries this script's latest version,
# instructions for scheduling it, and an alternate download method with cURL.
#
# Usage:
#   download-boundbook.sh -a ACCOUNT -k KEY -u AUDITUSER [-o OUTPUT]
#
# Options:
#   -a ACCOUNT    The FastBound account name (required)
#   -k KEY        The FastBound API key (required)
#   -u AUDITUSER  The email address of a valid FastBound user account (required)
#   -o OUTPUT     The output file path (defaults to ACCOUNT.pdf)
#   -s SERVER     The FastBound server URL (defaults to https://cloud.fastbound.com)
#   -h            Show this help message
#
# Examples:
#   download-boundbook.sh -a myaccount -k my-api-key -u user@example.com
#   download-boundbook.sh -a myaccount -k my-api-key -u user@example.com -o ~/Books/mybook.pdf

set -e

SERVER="https://cloud.fastbound.com"
ACCOUNT=""
KEY=""
AUDITUSER=""
OUTPUT=""

show_help() {
    sed -n '2,31p' "$0" | sed 's/^# \?//'
    exit 1
}

while getopts "a:k:u:o:s:h" opt; do
    case $opt in
        a) ACCOUNT="$OPTARG" ;;
        k) KEY="$OPTARG" ;;
        u) AUDITUSER="$OPTARG" ;;
        o) OUTPUT="$OPTARG" ;;
        s) SERVER="$OPTARG" ;;
        h) show_help ;;
        *) show_help ;;
    esac
done

if [ -z "$ACCOUNT" ] || [ -z "$KEY" ] || [ -z "$AUDITUSER" ]; then
    show_help
fi

if [ -z "$OUTPUT" ]; then
    OUTPUT="./${ACCOUNT}.pdf"
fi

if [ ${#KEY} -ne 43 ]; then
    echo "Warning: Your API key doesn't look right--did you just copy part of the key?" >&2
fi

AUTH=$(echo -n "${ACCOUNT}:${KEY}" | base64)
URL="${SERVER}/${ACCOUNT}/api/Downloads/BoundBook"

RESPONSE=$(curl -s -X POST "$URL" \
    -H "Authorization: Basic ${AUTH}" \
    -H "X-AuditUser: ${AUDITUSER}" \
    -A "DownloadFastBoundBook")

if [ -z "$RESPONSE" ]; then
    echo "Bound book is not ready. Try again tomorrow." >&2
    exit 1
fi

PDF_URL=$(echo "$RESPONSE" | grep -o '"url":"[^"]*"' | sed 's/"url":"//;s/"$//')

if [ -z "$PDF_URL" ]; then
    echo "Download failed. Could not parse response." >&2
    exit 1
fi

if curl -s -o "$OUTPUT" -A "DownloadFastBoundBook" "$PDF_URL"; then
    echo "Download successful: $OUTPUT"
    exit 0
else
    echo "Download failed." >&2
    exit 1
fi
