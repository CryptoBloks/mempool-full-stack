# Docker Commands and Troubleshooting Guide

## Container Base OS Information

All containers are now based on Ubuntu 24.04 LTS, providing a consistent and modern base operating system across all services.

### Common Ubuntu Commands
```bash
# Update package lists
docker-compose exec <service> apt update

# Install additional packages
docker-compose exec <service> apt install <package-name>

# Check OS version
docker-compose exec <service> cat /etc/os-release

# Check Ubuntu version
docker-compose exec <service> lsb_release -a
```

### Service-Specific Information

#### Bitcoin Core
- Base OS: Ubuntu 24.04 LTS
- Package Manager: apt
- Bitcoin Core Version: 25.0
- Common commands:
  ```bash
  # Update Bitcoin Core
  docker-compose exec bitcoin apt update && docker-compose exec bitcoin apt install bitcoind

  # Check Bitcoin Core version
  docker-compose exec bitcoin bitcoind --version
  ```

#### Fulcrum
- Base OS: Ubuntu 24.04 LTS
- Package Manager: apt
- Fulcrum Version: 1.9.0
- Common commands:
  ```bash
  # Update Fulcrum
  docker-compose exec fulcrum apt update && docker-compose exec fulcrum apt install fulcrum

  # Check Fulcrum version
  docker-compose exec fulcrum Fulcrum --version
  ```

#### MariaDB
- Base OS: Ubuntu 24.04 LTS
- Package Manager: apt
- MariaDB Version: 10.6
- Common commands:
  ```bash
  # Update MariaDB
  docker-compose exec mariadb apt update && docker-compose exec mariadb apt install mariadb-server

  # Check MariaDB version
  docker-compose exec mariadb mysql --version
  ```

#### Mempool
- Base OS: Ubuntu 24.04 LTS
- Package Manager: apt
- Node.js Version: 20.x
- Common commands:
  ```bash
  # Update Node.js
  docker-compose exec mempool apt update && docker-compose exec mempool apt install nodejs

  # Check Node.js version
  docker-compose exec mempool node --version
  ```

### Building Custom Images
```bash
# Build all images
docker-compose build

# Build specific service
docker-compose build bitcoin

# Build and start services
docker-compose up -d --build

# Force rebuild without cache
docker-compose build --no-cache
```

Note: The move to Ubuntu 24.04 LTS provides:
- Consistent package management across all services
- Latest security updates and patches
- Modern system libraries and tools
- Better compatibility with newer software versions
- Long-term support until 2029

## Basic Container Management

### Starting Services
```bash
# Start all services in detached mode
docker-compose up -d

# Start specific services
docker-compose up -d bitcoin fulcrum

# Start services and rebuild images
docker-compose up -d --build

# Start services and force recreation of containers
docker-compose up -d --force-recreate
```

### Stopping Services
```bash
# Stop all services
docker-compose down

# Stop specific services
docker-compose stop bitcoin fulcrum

# Stop and remove volumes (WARNING: This will delete data)
docker-compose down -v
```

### Viewing Container Status
```bash
# List all containers and their status
docker-compose ps

# List all containers including stopped ones
docker-compose ps -a

# Show container resource usage
docker stats
```

## Logs and Monitoring

### Viewing Logs
```bash
# View logs for all services
docker-compose logs

# View logs for specific service
docker-compose logs bitcoin

# Follow logs in real-time
docker-compose logs -f

# Follow logs for specific service
docker-compose logs -f bitcoin

# Show last N lines of logs
docker-compose logs --tail=100 bitcoin

# Show logs since timestamp
docker-compose logs --since="2024-03-20T00:00:00" bitcoin

# Show logs with timestamps
docker-compose logs -t bitcoin
```

### Container Shell Access
```bash
# Access Bitcoin Core container shell
docker-compose exec bitcoin bash

# Access Fulcrum container shell
docker-compose exec fulcrum bash

# Access MariaDB container shell
docker-compose exec mariadb bash

# Access Mempool container shell
docker-compose exec mempool bash
```

## Troubleshooting Commands

### Bitcoin Core
```bash
# Check Bitcoin Core status
docker-compose exec bitcoin bitcoin-cli getblockchaininfo

# Check Bitcoin Core network info
docker-compose exec bitcoin bitcoin-cli getnetworkinfo

# Check Bitcoin Core mempool info
docker-compose exec bitcoin bitcoin-cli getmempoolinfo

# Check Bitcoin Core peer info
docker-compose exec bitcoin bitcoin-cli getpeerinfo

# Check Bitcoin Core debug log
docker-compose exec bitcoin tail -f /home/bitcoin/.bitcoin/debug.log
```

### Fulcrum
```bash
# Check Fulcrum status
docker-compose exec fulcrum fulcrum-cli status

# Check Fulcrum connections
docker-compose exec fulcrum fulcrum-cli connections

# Check Fulcrum debug log
docker-compose exec fulcrum tail -f /home/fulcrum/.fulcrum/fulcrum.log
```

### MariaDB
```bash
# Access MariaDB command line
docker-compose exec mariadb mysql -u root -p

# Check MariaDB status
docker-compose exec mariadb mysqladmin -u root -p status

# Check MariaDB error log
docker-compose exec mariadb tail -f /var/log/mysql/error.log

# Common MariaDB commands
docker-compose exec mariadb mysql -u root -p -e "SHOW DATABASES;"
docker-compose exec mariadb mysql -u root -p -e "SHOW TABLES FROM mempool;"
```

### Mempool
```bash
# Check Mempool logs
docker-compose logs -f mempool

# Check Mempool container status
docker-compose exec mempool ps aux

# Check Mempool configuration
docker-compose exec mempool cat /etc/mempool/mempool-config.json
```

## Maintenance Commands

### Backup and Restore
```bash
# Backup Bitcoin Core data
docker-compose exec bitcoin tar -czf /backup/bitcoin-backup.tar.gz /home/bitcoin/.bitcoin

# Backup Fulcrum data
docker-compose exec fulcrum tar -czf /backup/fulcrum-backup.tar.gz /home/fulcrum/.fulcrum

# Backup MariaDB data
docker-compose exec mariadb mysqldump -u root -p mempool > backup/mempool-db-backup.sql

# Restore MariaDB backup
docker-compose exec -i mariadb mysql -u root -p mempool < backup/mempool-db-backup.sql
```

### Container Maintenance
```bash
# Remove unused containers
docker container prune

# Remove unused images
docker image prune

# Remove unused volumes
docker volume prune

# Remove all unused Docker objects
docker system prune
```

### Network Troubleshooting
```bash
# Check Docker network
docker network ls
docker network inspect bitcoin_network

# Check container IP addresses
docker-compose exec bitcoin ip addr
docker-compose exec fulcrum ip addr
docker-compose exec mariadb ip addr
docker-compose exec mempool ip addr

# Test network connectivity between containers
docker-compose exec bitcoin ping fulcrum
docker-compose exec bitcoin ping mariadb
docker-compose exec bitcoin ping mempool
```

## Health Check Commands

### Check Service Health
```bash
# Check Bitcoin Core health
docker-compose exec bitcoin bitcoin-cli getblockchaininfo

# Check Fulcrum health
docker-compose exec fulcrum fulcrum-cli status

# Check MariaDB health
docker-compose exec mariadb mysqladmin -u root -p ping

# Check Mempool health
curl http://localhost:80/api/v1/fees/recommended
```

### Restart Services
```bash
# Restart all services
docker-compose restart

# Restart specific service
docker-compose restart bitcoin

# Restart service and follow logs
docker-compose restart bitcoin && docker-compose logs -f bitcoin
```

## Common Issues and Solutions

### Service Won't Start
```bash
# Check service logs
docker-compose logs bitcoin

# Check service configuration
docker-compose config

# Check service dependencies
docker-compose ps
```

### Connection Issues
```bash
# Check Bitcoin Core RPC connection
docker-compose exec bitcoin bitcoin-cli getblockchaininfo

# Check Fulcrum connection to Bitcoin Core
docker-compose exec fulcrum fulcrum-cli status

# Check MariaDB connection
docker-compose exec mariadb mysqladmin -u root -p ping

# Check Mempool connection to Fulcrum
curl http://localhost:80/api/v1/fees/recommended
```

### Resource Issues
```bash
# Check container resource usage
docker stats

# Check container memory limits
docker-compose exec bitcoin free -h

# Check container disk usage
docker-compose exec bitcoin df -h
```

## Container Updates and Maintenance

### Updating Containers
```bash
# Pull latest images for all services
docker-compose pull

# Pull latest image for specific service
docker-compose pull bitcoin

# Update and restart all services
docker-compose pull && docker-compose up -d

# Update specific service
docker-compose pull bitcoin && docker-compose up -d bitcoin

# Force rebuild of all services
docker-compose build --no-cache

# Force rebuild specific service
docker-compose build --no-cache bitcoin

# Update and rebuild all services
docker-compose pull && docker-compose build && docker-compose up -d

# Update and rebuild specific service
docker-compose pull bitcoin && docker-compose build bitcoin && docker-compose up -d bitcoin
```

### Version Management
```bash
# Check current image versions
docker-compose images

# Check available tags for Bitcoin Core
docker-compose pull bitcoin:latest

# Check available tags for Fulcrum
docker-compose pull fulcrum:latest

# Check available tags for MariaDB
docker-compose pull mariadb:latest

# Check available tags for Mempool
docker-compose pull mempool:latest
```

### Update Best Practices
1. Always backup your data before updating:
```bash
# Backup all data
./backup.sh  # If you have a backup script
# OR
docker-compose exec bitcoin tar -czf /backup/bitcoin-backup.tar.gz /home/bitcoin/.bitcoin
docker-compose exec fulcrum tar -czf /backup/fulcrum-backup.tar.gz /home/fulcrum/.fulcrum
docker-compose exec mariadb mysqldump -u root -p mempool > backup/mempool-db-backup.sql
```

2. Update services in the correct order:
```bash
# Stop all services
docker-compose down

# Update Bitcoin Core first
docker-compose pull bitcoin
docker-compose up -d bitcoin

# Wait for Bitcoin Core to be ready
docker-compose logs -f bitcoin

# Update Fulcrum
docker-compose pull fulcrum
docker-compose up -d fulcrum

# Update MariaDB
docker-compose pull mariadb
docker-compose up -d mariadb

# Update Mempool last
docker-compose pull mempool
docker-compose up -d mempool
```

3. Verify updates:
```bash
# Check all services are running
docker-compose ps

# Check Bitcoin Core version
docker-compose exec bitcoin bitcoin-cli getnetworkinfo

# Check Fulcrum version
docker-compose exec fulcrum fulcrum-cli version

# Check MariaDB version
docker-compose exec mariadb mysql --version

# Check Mempool version
docker-compose exec mempool cat /etc/mempool/version.txt
```

4. Rollback if needed:
```bash
# Stop the service
docker-compose stop mempool

# Pull previous version
docker-compose pull mempool:v1.0.0  # Replace with actual version

# Start the service
docker-compose up -d mempool
```

Remember to:
- Always check the changelog/release notes before updating
- Test updates in a staging environment if possible
- Keep track of your current versions
- Have a rollback plan ready
- Monitor services after updates
- Check logs for any issues after updates

Remember to replace any passwords or sensitive information with your actual values when using these commands.

# Common Docker Commands

## Prerequisites

### Check Docker Installation
```bash
docker --version
docker-compose --version
```

### Check System Requirements
```bash
# Check available disk space
df -h

# Check available memory
free -h

# Check CPU information
lscpu
```

## Initial Setup

### Clone Repository
```bash
git clone <repository-url>
cd mempool.space-docker-full-stack
```

### Environment Setup
```bash
# Copy environment file
cp .env.example .env

# Edit environment file
nano .env
```

### Run Setup Script
```bash
# Make script executable
chmod +x setup.sh

# Run setup
./setup.sh
```

## Building and Starting Services

### Build Process
```bash
# Make build script executable
chmod +x build.sh

# Build all services
./build.sh

# Build specific service
docker-compose build <service-name>

# View build logs
docker-compose logs --tail=50
```

### Starting Services
```bash
# Start all services
docker-compose up -d

# Start specific service
docker-compose up -d <service-name>

# View service status
docker-compose ps
```

## Monitoring and Logs

### Service Status
```bash
# Check all services
docker-compose ps

# Check specific service
docker-compose ps <service-name>

# Check service health
docker-compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Health}}"
```

### Viewing Logs
```bash
# All services
docker-compose logs -f

# Specific service
docker-compose logs -f <service-name>

# Last 100 lines
docker-compose logs --tail=100 -f

# Since last 5 minutes
docker-compose logs --since 5m -f
```

## Maintenance

### Updating Services
```bash
# Update all services
./build.sh

# Update specific service
docker-compose build <service-name>
docker-compose up -d <service-name>
```

### Backup
```bash
# Backup data directories
tar -czf backup-$(date +%Y%m%d).tar.gz data/

# Backup specific service
tar -czf bitcoin-backup-$(date +%Y%m%d).tar.gz data/bitcoin/
```

### Cleanup
```bash
# Remove unused containers
docker container prune

# Remove unused images
docker image prune

# Remove unused volumes
docker volume prune

# Remove all unused objects
docker system prune
```

## Troubleshooting

### Service Issues
```bash
# Check service logs
docker-compose logs <service-name>

# Restart service
docker-compose restart <service-name>

# Rebuild and restart service
docker-compose up -d --build <service-name>
```

### Network Issues
```bash
# Check network configuration
docker network ls
docker network inspect bitcoin_network

# Check container IPs
docker-compose exec <service-name> ip addr
```

### Permission Issues
```bash
# Fix data directory permissions
sudo chown -R 1000:1000 data/bitcoin
sudo chown -R 1000:1000 data/fulcrum
sudo chown -R 1000:1000 data/mempool
sudo chown -R 999:999 data/mariadb
```

## Ubuntu-Specific Commands

### System Updates
```bash
# Update package lists
sudo apt update

# Upgrade packages
sudo apt upgrade

# Clean up
sudo apt clean
sudo apt autoremove
```

### Docker Management
```bash
# Check Docker service status
sudo systemctl status docker

# Restart Docker service
sudo systemctl restart docker

# View Docker logs
sudo journalctl -fu docker
```

### Resource Monitoring
```bash
# Monitor system resources
htop

# Monitor disk I/O
iostat -x 1

# Monitor network
iftop
```

## Common Issues and Solutions

### 1. Service Won't Start
```bash
# Check logs
docker-compose logs <service-name>

# Check disk space
df -h

# Check memory
free -h
```

### 2. Connection Issues
```bash
# Check network
docker network inspect bitcoin_network

# Test connectivity
docker-compose exec <service-name> ping <target-service>
```

### 3. Permission Denied
```bash
# Fix permissions
sudo chown -R $(id -u):$(id -g) data/
```

### 4. Build Failures
```bash
# Clean build
docker-compose build --no-cache <service-name>

# Check build logs
docker-compose build <service-name> --progress=plain
```

### 5. Container Health Issues
```bash
# Check health status
docker-compose ps

# View health check logs
docker inspect --format='{{json .State.Health}}' <container-id> | jq
```

## Security Commands

### SSL Certificate Management
```bash
# Check certificate validity
openssl x509 -in config/fulcrum/fulcrum.cert -text -noout

# Generate new certificates
./setup.sh --regenerate-certs
```

### Access Control
```bash
# Check RPC access
curl --user <rpc-user>:<rpc-password> --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getblockchaininfo", "params": []}' -H 'content-type: text/plain;' http://localhost:8332/

# Test MariaDB connection
docker-compose exec mariadb mysql -u root -p
```

## Maintenance Tasks

### Regular Updates
```bash
# Update all services
./build.sh

# Update specific service
docker-compose build <service-name>
docker-compose up -d <service-name>
```

### Backup Schedule
```bash
# Daily backup
0 0 * * * tar -czf /backup/backup-$(date +\%Y\%m\%d).tar.gz /path/to/data/

# Weekly backup
0 0 * * 0 tar -czf /backup/weekly-backup-$(date +\%Y\%m\%d).tar.gz /path/to/data/
```

### Log Rotation
```bash
# Configure log rotation
sudo nano /etc/logrotate.d/docker

# Manual log rotation
docker-compose logs --tail=1000 > logs-$(date +%Y%m%d).log
```

## Performance Tuning

### Resource Limits
```bash
# Check container resource usage
docker stats

# Set resource limits in docker-compose.yml
services:
  bitcoin:
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 4G
```

### Network Optimization
```bash
# Check network performance
docker-compose exec bitcoin ping fulcrum

# Monitor network traffic
docker-compose exec bitcoin iftop
```

### Disk I/O Optimization
```bash
# Check disk I/O
docker-compose exec bitcoin iostat -x 1

# Monitor disk usage
docker-compose exec bitcoin df -h
``` 