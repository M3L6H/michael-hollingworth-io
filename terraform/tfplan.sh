#!/usr/bin/env sh

env="dev"
[ -z "$1" ] || env="$1"

envdir="environments/${env}"
vars="${env}.tfvars"
plan="${env}.tfplan"
preview="${envdir}/${plan}.preview"

rm "$preview" 2>/dev/null
terraform -chdir="$envdir" plan -var-file "$vars" -out "$plan" | tee "$preview"
