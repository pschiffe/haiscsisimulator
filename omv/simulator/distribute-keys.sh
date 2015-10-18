#!/bin/bash

set -eu

if [ ! -f /root/.ssh/id_rsa ]; then
    ssh-keygen -b 2048 -t rsa -f /root/.ssh/id_rsa -N ''

    for i in client{1..2}; do
        ssh-copy-id -i /root/.ssh/id_rsa.pub $i
    done
else
    for i in client{1..2}; do
        ssh $i echo
    done
fi

