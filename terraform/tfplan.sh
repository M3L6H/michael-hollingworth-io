#!/usr/bin/env sh

env="dev"
[ -z "$1" ] || env="$1"

vars="${env}.tfvars"
plan="${env}.tfplan"
preview="${plan}.preview"

rm "$preview" 2>/dev/null
terraform plan -var-file "$vars" -out "$plan" | tee "$preview"
