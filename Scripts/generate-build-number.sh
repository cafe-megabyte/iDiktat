#!/bin/sh
# Writes the build number (timestamp YYYYMMDD.HHMMSS) as a C constant.
# Run by the aggregate target "Generate Build Number" before every build. App and keyboard
# preprocess their Info.plist with this file (INFOPLIST_PREPROCESS) and therefore always
# carry the same CFBundleVersion.
#
# The build runs scripts in a sandbox (ENABLE_USER_SCRIPT_SANDBOXING) that only allows writing
# the declared output file. So write it directly, without a temporary file.

set -eu

output_path=${1:?"missing output path"}
printf '#define BUILD_NUMBER_VALUE %s\n' "$(date '+%Y%m%d.%H%M%S')" > "$output_path"
