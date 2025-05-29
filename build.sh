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

# Clean up old images
echo "Cleaning up old images..."
docker-compose down
docker system prune -f

# Build images
echo "Building images..."
docker-compose build --no-cache

# Verify images
echo "Verifying images..."
docker-compose images

# Test build
echo "Testing build..."
docker-compose up -d

# Wait for services to start
echo "Waiting for services to start..."
sleep 10

# Check service health
echo "Checking service health..."
docker-compose ps

# Check logs
echo "Checking logs..."
docker-compose logs --tail=50

echo "Build completed successfully!"
echo "To start the services, run: docker-compose up -d"
echo "To view logs, run: docker-compose logs -f" 