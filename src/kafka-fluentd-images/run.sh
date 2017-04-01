#!/bin/bash

if [[ $VERBOSE ]]; then
  set -ex
  fluentdargs="-vv"
else
  set -e
  fluentdargs=
fi

exec fluentd $fluentdargs
