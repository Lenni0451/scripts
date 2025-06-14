#!/bin/bash

sudo docker run -d -p 127.0.0.1:9000:9000 --name portainer --restart=no -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest
