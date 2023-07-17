#!/bin/bash


tar -xzvf data1.tar.gz -C /
chmod -R 777 /data1

tar -xzvf outmongo.tar.gz -C /

docker load -i nsmetabobank.tar.gz

docker load -i mongod.tar.gz

docker load -i omics.tar.gz

docker-compose up -d

echo "Now you can use your metabobank in $(hostname -I | awk '{print $1}'):8085 or 127.0.0.1:8085"
