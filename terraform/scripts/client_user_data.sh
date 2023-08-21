#!/bin/bash

# Retrieve instance id
INSTANCE_ID="$(ec2-metadata --instance-id | grep -Eo 'i-[a-z0-9]+')"
echo "Instance ID is: ${INSTANCE_ID}"

# Retreive region
REGION="$(ec2-metadata --availability-zone | grep -Eo '[-a-z]+-[0-9]')"
echo "Region is: ${REGION}"

# Install Ruby
echo "Installing Ruby..."
yum update
yum install ruby -y
which ruby >/dev/null 2>&1 && echo "Successfully installed ruby" || echo "ruby installation failed"

# Install CodeDeploy agent
echo "Installing CodeDeploy agent..."
cd /home/ec2-user
wget "https://aws-codedeploy-${REGION}.s3.${REGION}.amazonaws.com/latest/install"
chmod +x ./install
./install auto
service codedeploy-agent status && echo "Successfully installed CodeDeploy agent" || echo "CodeDeploy agent installation failed"
rm install

# Install node 18
echo "Installing node 18..."
curl --silent --location https://rpm.nodesource.com/setup_18.x | bash -
yum -y install nodejs
which node >/dev/null 2>&1 && echo "Successfully installed node" || echo "node installation failed"

# Install pm2
echo "Installing pm2..."
npm i -g pm2
which pm2 >/dev/null 2>&1 && echo "Successfully installed pm2" || echo "pm2 installation failed"
