# Docker Commands and Troubleshooting Guide

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