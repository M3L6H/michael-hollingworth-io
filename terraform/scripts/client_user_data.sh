#!/bin/bash

# Install node 18
curl --silent --location https://rpm.nodesource.com/setup_18.x | bash -
yum -y install nodejs

# Install pm2
npm i -g pm2
