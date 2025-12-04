#!/usr/bin/env python3
"""
Download a single, compliant A&D bound book from a single FastBound account.

A simple script to download a single, compliant A&D bound book from a single
FastBound account per ATF Ruling 2016-1.

SECURITY WARNING: This script requires your API key to be passed as a command-line
argument. On multi-user systems, command-line arguments are visible to all users
via process listing tools (e.g., ps). If you schedule this script as a task on a
shared system, other users may be able to see your API key.

https://fastb.co/DownloadFastBoundBook carries this script's latest version,
instructions for scheduling it, and an alternate download method with cURL.
"""

import argparse
import base64
import json
import sys
import urllib.request
import urllib.error


def main():
    parser = argparse.ArgumentParser(
        description="Download a single, compliant A&D bound book from a single FastBound account."
    )
    parser.add_argument("-a", "--account", required=True, help="The FastBound account name")
    parser.add_argument("-k", "--key", required=True, help="The FastBound API key")
    parser.add_argument("-u", "--audit-user", required=True, help="The email address of a valid FastBound user account")
    parser.add_argument("-o", "--output", help="The output file path (defaults to ACCOUNT.pdf)")
    parser.add_argument("-s", "--server", default="https://cloud.fastbound.com", help=argparse.SUPPRESS)

    args = parser.parse_args()

    output = args.output or f"./{args.account}.pdf"

    if len(args.key) != 43:
        print("Warning: Your API key doesn't look right--did you just copy part of the key?", file=sys.stderr)

    auth = base64.b64encode(f"{args.account}:{args.key}".encode()).decode()
    url = f"{args.server}/{args.account}/api/Downloads/BoundBook"

    headers = {
        "Authorization": f"Basic {auth}",
        "X-AuditUser": args.audit_user,
        "User-Agent": "DownloadFastBoundBook",
    }

    try:
        request = urllib.request.Request(url, method="POST", headers=headers)
        with urllib.request.urlopen(request) as response:
            if response.status == 204:
                print("Bound book is not ready. Try again tomorrow.", file=sys.stderr)
                sys.exit(1)

            data = json.loads(response.read().decode())
            pdf_url = data.get("url")

            if not pdf_url:
                print("Download failed. Could not parse response.", file=sys.stderr)
                sys.exit(1)

            pdf_request = urllib.request.Request(pdf_url, headers={"User-Agent": "DownloadFastBoundBook"})
            with urllib.request.urlopen(pdf_request) as pdf_response:
                with open(output, "wb") as f:
                    f.write(pdf_response.read())

            print(f"Download successful: {output}")
            sys.exit(0)

    except urllib.error.HTTPError as e:
        print(f"Download failed. Status code: {e.code}. Message: {e.reason}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"Exception occurred: {e.reason}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
