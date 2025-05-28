#!/bin/bash

# Exit on error
set -e

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
echo "Checking prerequisites..."
if ! command_exists docker; then
    echo "Error: Docker is not installed"
    exit 1
fi

if ! command_exists docker-compose; then
    echo "Error: Docker Compose is not installed"
    exit 1
fi

if ! command_exists openssl; then
    echo "Error: OpenSSL is not installed"
    exit 1
fi

# Create necessary directories
echo "Creating directories..."
mkdir -p data/{bitcoin,fulcrum,mempool,mariadb}
mkdir -p config/{bitcoin,fulcrum,mempool,mariadb/init}

# Set proper permissions
echo "Setting permissions..."
chmod 755 data/{bitcoin,fulcrum,mempool,mariadb}

# Generate SSL certificates for Fulcrum
echo "Generating SSL certificates..."
if [ ! -f config/fulcrum/fulcrum.key ] || [ ! -f config/fulcrum/fulcrum.cert ]; then
    openssl req -x509 -newkey rsa:4096 -keyout config/fulcrum/fulcrum.key -out config/fulcrum/fulcrum.cert -days 365 -nodes -subj "/CN=fulcrum" || {
        echo "Error: Failed to generate SSL certificates"
        exit 1
    }
fi

# Set proper permissions for SSL certificates
chmod 600 config/fulcrum/fulcrum.key
chmod 644 config/fulcrum/fulcrum.cert

# Create .env file if it doesn't exist
if [ ! -f .env ]; then
    if [ -f .env.example ]; then
        echo "Creating .env file from .env.example..."
        cp .env.example .env
        echo "Created .env file from .env.example. Please edit it with your desired values."
    else
        echo "Error: .env.example file not found"
        exit 1
    fi
else
    echo "Warning: .env file already exists. Skipping creation."
fi

# Validate .env file
echo "Validating .env file..."
if [ ! -f .env ]; then
    echo "Error: .env file not found"
    exit 1
fi

# Check if required variables are set
required_vars=(
    "BITCOIN_RPC_USER"
    "BITCOIN_RPC_PASSWORD"
    "MYSQL_ROOT_PASSWORD"
    "MYSQL_DATABASE"
    "MYSQL_USER"
    "MYSQL_PASSWORD"
)

for var in "${required_vars[@]}"; do
    if ! grep -q "^${var}=" .env; then
        echo "Error: Required variable ${var} not found in .env file"
        exit 1
    fi
done

echo "Setup completed successfully!" 