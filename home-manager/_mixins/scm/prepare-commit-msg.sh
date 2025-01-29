#!/bin/sh
# Thanks to https://felix.ehrenpfort.de/notes/2022-01-12-git-sign-off-commits-using-prepare-commit-msg-hook/

if ! command -v git > /dev/null ; then
    echo "error: command git not found"
    exit 1
fi

NAME=$(git config user.name)
EMAIL=$(git config user.email)

if [ -z "$NAME" ]; then
    echo "error: empty git config user.name"
    exit 1
fi

if [ -z "$EMAIL" ]; then
    echo "error: empty git config user.email"
    exit 1
fi

git interpret-trailers --if-exists doNothing --trailer \
    "Signed-off-by: $NAME <$EMAIL>" \
    --in-place "$1"
