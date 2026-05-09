#!/bin/bash
# generate_checksum.sh — Release checksum generator
#
# Run this script from the repository root before tagging a release.
# It stamps the current date into app.ver and rebuilds file.chk, which
# contains md5sums for all files shipped to the SD card (SD_ROOT/) and the
# v2_install/ directory (excluding demo.bin, which is built locally).
#
# Usage:
#   ./generate_checksum.sh
#
# Prerequisites: bash, date, md5sum, find

set -e

#set release date before generation
date +"%Y-%m-%d_%H:%M:%S" > SD_ROOT/wz_mini/usr/bin/app.ver

rm -f file.chk
find SD_ROOT/ -type f -exec md5sum "{}" + > file.chk

#Ignore demo.bin
find v2_install -type f ! -name "demo.bin" -exec md5sum "{}" + >> file.chk
