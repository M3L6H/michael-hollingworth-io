#!/usr/bin/env bash

echo "Stopping all processes..."
pm2 stop all

echo "Listing processes..."
pm2 list
