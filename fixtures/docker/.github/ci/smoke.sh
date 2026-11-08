#!/usr/bin/env bash
# The fixture's smoke test: run the image's CLI. image-check passes the image
# tag as $1. self-test builds with FIXTURE_VERSION=1.2.3, so the version check
# also covers the build-args input end to end.
set -euo pipefail
image=$1

version=$(docker run --rm "$image" --version)
if [[ $version != "fixture-cli 1.2.3" ]]; then
  echo "::error title=smoke::--version printed '$version', expected 'fixture-cli 1.2.3'"
  exit 1
fi

greeting=$(docker run --rm "$image" greet ci)
if [[ $greeting != "hello, ci" ]]; then
  echo "::error title=smoke::greet printed '$greeting', expected 'hello, ci'"
  exit 1
fi

echo "smoke ok: $version"
