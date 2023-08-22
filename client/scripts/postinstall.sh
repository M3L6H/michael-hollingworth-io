#!/usr/bin/env bash

echo "Installing dependencies..."
sudo chown -R ec2-user /home/ec2-user/client
npm --prefix /home/ec2-user/client install
