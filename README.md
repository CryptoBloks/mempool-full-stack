# Mempool.space Docker Full Stack

This repository contains a Docker Compose setup for running a complete mempool.space stack, including:
- Bitcoin Core
- Fulcrum (Electrum server)
- MariaDB
- Mempool.space frontend and backend

All services are built on Ubuntu 24.04 LTS for consistency and long-term support.

## Prerequisites

- Docker
- Docker Compose
- OpenSSL (for certificate generation)
- At least 500GB of free disk space (for Bitcoin blockchain)
- 8GB+ RAM recommended

## Quick Start

1. Clone this repository:
```bash
git clone <repository-url>
cd mempool.space-docker-full-stack
```

2. Create your environment file:
```bash
cp .env.example .env
```

3. Edit the `.env` file with your desired values. Make sure to:
   - Change all default passwords
   - Use strong, unique passwords
   - Keep this file secure as it contains sensitive information

4. Run the setup script:
```bash
./setup.sh
```

5. Build and start the services:
```bash
./build.sh
```

## Base System Information

All containers are built on Ubuntu 24.04 LTS, providing:
- Consistent package management (apt)
- Latest security updates and patches
- Modern system libraries and tools
- Better compatibility with newer software versions
- Long-term support until 2029

### Service Versions
- Bitcoin Core: 25.0
- Fulcrum: 1.9.0
- MariaDB: 10.6
- Mempool: 2.3.0
- Node.js: 20.x

## Port Configuration and Security

### Exposed Ports (External Access)
- 80: Mempool.space web interface
- 8333: Bitcoin Core P2P (required for Bitcoin network)

### Protected Ports (Internal Only)
- 8332: Bitcoin Core RPC
- 50001: Fulcrum Electrum protocol
- 50002: Fulcrum SSL
- 3306: MariaDB

All internal services are protected and only accessible within the Docker network. For detailed security information, see [AGENTS.md](AGENTS.md).

## Building from Source

The project uses custom Dockerfiles to build each service from source on Ubuntu 24.04. This ensures:
- Consistent base system across all services
- Latest security patches
- Optimized builds for your system
- Full control over the build process

### Build Process
1. The `build.sh` script handles the entire build process:
   - Checks prerequisites
   - Cleans up old images
   - Builds new images
   - Verifies the build
   - Tests service health

2. To rebuild a specific service:
```bash
docker-compose build <service-name>
```

3. To rebuild all services:
```bash
./build.sh
```

## Service Details

### Bitcoin Core
- Base: Ubuntu 24.04 LTS
- Ports:
  - 8332: RPC (internal only)
  - 8333: P2P (external)
- Data directory: `./data/bitcoin`
- Config directory: `./config/bitcoin`
- Health check: Monitors blockchain status
- Security: RPC access restricted to Docker network

### Fulcrum (Electrum Server)
- Base: Ubuntu 24.04 LTS
- Ports:
  - 50001: Electrum protocol (internal only)
  - 50002: SSL (internal only)
- Data directory: `./data/fulcrum`
- Config directory: `./config/fulcrum`
- SSL certificates: Automatically generated during setup
- Health check: Monitors service availability
- Security: SSL/TLS enabled, internal access only

### MariaDB
- Base: Ubuntu 24.04 LTS
- Port: 3306 (internal only)
- Data directory: `./data/mariadb`
- Config directory: `./config/mariadb`
- Database: mempool
- Health check: Monitors database connectivity
- Security: Internal access only, authentication required

### Mempool.space
- Base: Ubuntu 24.04 LTS
- Port: 80 (external)
- Data directory: `./data/mempool`
- Config directory: `./config/mempool`
- Health check: Monitors API availability
- Security: Public web interface, protected backend

## Initial Sync

The initial Bitcoin blockchain sync may take several days depending on your internet connection and hardware. You can monitor the progress through the Bitcoin Core logs:

```bash
docker-compose logs -f bitcoin
```

## Security Considerations

1. Change the default RPC credentials in the `.env` file
2. Consider using a reverse proxy with SSL for the mempool.space frontend
3. Restrict RPC access to trusted IPs in production
4. Regularly backup the data directories
5. SSL certificates for Fulcrum are automatically generated during setup
6. MariaDB credentials should be changed from defaults in production
7. Keep your `.env` file secure and never commit it to version control
8. Review and follow the [AGENTS.md](AGENTS.md) for best practices

## Maintenance

### Updating
```bash
# Update all services
./build.sh

# Update specific service
docker-compose build <service-name>
docker-compose up -d <service-name>
```

### Backup
Regularly backup the following directories:
- `./data/bitcoin`
- `./data/fulcrum`
- `./data/mempool`
- `./data/mariadb`

### Monitoring
Monitor the services using:
```bash
docker-compose ps
docker-compose logs -f
```

## Troubleshooting

1. If Bitcoin Core fails to start, check the logs:
```bash
docker-compose logs bitcoin
```

2. If Fulcrum fails to connect to Bitcoin Core, verify the RPC credentials and wait for Bitcoin Core to be fully synced.

3. If Mempool.space fails to connect to Fulcrum, ensure Fulcrum is fully synced and the connection details are correct.

4. If MariaDB fails to start, check the logs:
```bash
docker-compose logs mariadb
```

5. If services are not starting in the correct order, check the health checks:
```bash
docker-compose ps
```

6. If you see connection errors, verify your `.env` file settings match the service configurations.

## Project Structure

```
.
├── config/
│   ├── bitcoin/
│   │   └── bitcoin.conf
│   ├── fulcrum/
│   │   ├── fulcrum.conf
│   │   ├── fulcrum.key
│   │   └── fulcrum.cert
│   ├── mempool/
│   │   └── mempool-config.json
│   └── mariadb/
│       └── init/
│           └── 01-init.sql
├── data/
│   ├── bitcoin/
│   ├── fulcrum/
│   ├── mempool/
│   └── mariadb/
├── AGENTS.md
├── Dockerfile.bitcoin
├── Dockerfile.fulcrum
├── Dockerfile.mariadb
├── Dockerfile.mempool
├── docker-compose.yml
├── setup.sh
├── build.sh
├── .env.example
└── README.md
```

## License

This project is licensed under the MIT License - see the LICENSE file for details. 