#!/bin/bash
ensure_docker_installed() {
    if ! command_exists docker; then
        echo "Installing Docker ..."
        curl -fsSL https://get.docker.com | sudo sh -
        sudo gpasswd -a $(whoami) docker && sudo reboot
    else
        echo "Docker is already installed"
    fi
}

ensure_docker_installed
