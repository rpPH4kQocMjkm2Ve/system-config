#!/bin/bash

if [ ! -d "./etc" ]; then
    echo "Run from repo root."
    exit 1
fi

sudo rsync -a --chown=root:root --chmod=D755,F644 ./etc/ /etc/
