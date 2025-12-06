#!/bin/sh
HOSTNAME="builder"
ssh-keygen -R "$HOSTNAME"
ssh-keyscan -H "$HOSTNAME" >> ~/.ssh/known_hosts
