#!/usr/bin/bash

# SPDX-License-Identifier: GPL-3.0-or-later

# Script to handle translations of os-installer's config.yaml

yaml_file="config.yaml"
pot_file="po/config.pot"
pot_script="po/config_to_pot.py"

# sanity check
if [ ! -f "$pot_script" -o ! -f "$yaml_file" ]
then
  echo Run this script from the folder that contains $yaml_file and $pot_script
  exit 1
fi


echo Updating os-installer translations for "$yaml_file"
python "$pot_script" "$yaml_file"


echo Updating .po files from "$pot_file"
for po_file in po/*.po; do
  [ -f "$po_file" ] || break
  echo "  $po_file"
  msgmerge -qU "$po_file" "$pot_file"
done


echo Generating .mo files
for po_file in po/*.po; do
  file_name=$(basename "$po_file")
  language_code=${file_name%%_*}

  lc_folder="po/$language_code/LC_MESSAGES/"
  mkdir -p "$lc_folder"

  lc_file="$lc_folder/os-installer-config.mo"
  echo "  $lc_file"
  msgmerge -qo - "$po_file" "$pot_file" | msgfmt -c -o "$lc_file" -
done
