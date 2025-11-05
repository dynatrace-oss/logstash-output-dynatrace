#!/bin/bash

if [ $(command -v apt-get) ]; then
    sudo apt-get install -y make gcc
else
    sudo microdnf install -y make gcc
fi
