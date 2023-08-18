#!/usr/bin/env sh

env="dev"
[ -z "$1" ] || env="$1"

plan="${env}.tfplan"
preview="${plan}.preview"
out="${env}.tfout"

terraform apply "$plan" | tee "$out"
