#!/usr/bin/env sh

env="dev"
[ -z "$1" ] || env="$1"

envdir="environments/${env}"
plan="${env}.tfplan"
preview="${plan}.preview"
out="${envdir}/${env}.tfout"

terraform -chdir="$envdir" apply "$plan" | tee "$out"
