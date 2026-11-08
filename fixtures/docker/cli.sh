#!/bin/sh
# The fixture image's CLI. The build stage replaces @VERSION@ with the
# FIXTURE_VERSION build arg.
set -eu

case "${1:-}" in
  --version) echo "fixture-cli @VERSION@" ;;
  greet) echo "hello, ${2:-world}" ;;
  *)
    echo "usage: fixture-cli --version | greet [name]" >&2
    exit 2
    ;;
esac
