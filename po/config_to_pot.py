#!/bin/python3

# SPDX-License-Identifier: GPL-3.0-or-later

import argparse
from pathlib import Path
import yaml

parser = argparse.ArgumentParser(
    prog='config_to_pot',
    description='Create a .pot file for an os-installer config')
parser.add_argument('config_path', type=Path, default=None)

args = parser.parse_args()

if not args.config_path:
    parser.print_usage()
    exit(1)


def add_to_pot(text, pot_file):
    pot_file.write(f'msgid "{text}"\nmsgstr ""\n\n')


def handle_choices(choices, pot_file):
    for choice in choices:
        if 'name' in choice:
            add_to_pot(choice['name'], pot_file)
        else:
            print(f'Invalid choice: {choice}')
        if 'description' in choice:
            add_to_pot(choice['description'], pot_file)
        if 'options' in choice:
            options = choice['options']
            for option in options:
                if 'name' in option:
                    add_to_pot(option['name'], pot_file)
                elif not 'name' in option and not 'option' in option:
                    print(f'Invalid option: {option}')


def handle_desktop(desktops, pot_file):
    for desktop in desktops:
        if 'name' in desktop:
            add_to_pot(desktop['name'], pot_file)
        else:
            print(f'Invalid desktop: {desktop}')
        if 'description' in desktop:
            add_to_pot(desktop['description'], pot_file)


def handle_config(config, pot_file):
    if 'welcome_page' in config:
        welcome_page = config['welcome_page']
        if 'text' in welcome_page:
            add_to_pot(welcome_page['text'], pot_file)

    if 'desktop' in config:
        handle_desktop(config['desktop'], pot_file)

    if 'additional_software' in config:
        handle_choices(config['additional_software'], pot_file)

    if 'additional_features' in config:
        handle_choices(config['additional_features'], pot_file)


def write_pot_header(pot_file):
    pot_header = \
        '''# SOME DESCRIPTIVE TITLE.\n''' \
        '''# Copyright (C) YEAR THE PACKAGE'S COPYRIGHT HOLDER\n''' \
        '''# This file is distributed under the same license as the os-installer package.\n''' \
        '''# FIRST AUTHOR <EMAIL@ADDRESS>, YEAR.\n''' \
        '''#\n''' \
        '''msgid ""\n''' \
        '''msgstr ""\n''' \
        '''"Project-Id-Version: os-installer-config\\n"\n''' \
        '''"Report-Msgid-Bugs-To: \\n"\n''' \
        '''"POT-Creation-Date: 2023-08-18 03:39+0100\\n"\n''' \
        '''"PO-Revision-Date: YEAR-MO-DA HO:MI+ZONE\\n"\n''' \
        '''"Last-Translator: FULL NAME <EMAIL@ADDRESS>\\n"\n''' \
        '''"Language-Team: LANGUAGE <LL@li.org>\\n"\n''' \
        '''"Language: \\n"\n''' \
        '''"MIME-Version: 1.0\\n"\n''' \
        '''"Content-Type: text/plain; charset=UTF-8\\n"\n''' \
        '''"Content-Transfer-Encoding: 8bit\\n"\n\n'''
    pot_file.write(pot_header)


try:
    with open(args.config_path, 'r') as config_file:
        config = yaml.load(config_file, Loader=yaml.Loader)

    po_folder = args.config_path.parent / 'po'
    po_folder.mkdir(exist_ok=True)

    pot_path = po_folder / 'config.pot'
    with open(pot_path, 'w') as pot_file:
        write_pot_header(pot_file)
        handle_config(config, pot_file)
except:
    print('Could not find or parse provided config')
    exit(1)
