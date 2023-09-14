#!/usr/bin/env sh

env="dev"
[ -z "$1" ] || env="$1"

envdir="environments/${env}"

terraform -chdir="$envdir" fmt
terraform -chdir="$envdir" validate
