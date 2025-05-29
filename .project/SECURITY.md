# Security Documentation

## Base System Security

All services are built on Ubuntu 24.04 LTS, providing:
- Regular security updates and patches
- Modern security features and hardening
- Long-term support until 2029
- Consistent security baseline across all services

### Ubuntu 24.04 Security Features
- AppArmor for container isolation
- Secure boot support
- Regular security updates
- Modern cryptography libraries
- System-wide security policies

## Network Architecture

### Network Configuration
- Custom bridge network: `bitcoin_network`
- Subnet: `172.16.0.0/16`
- Static IP assignments:
  - Bitcoin Core: `172.16.0.2`
  - Fulcrum: `172.16.0.3`
  - MariaDB: `172.16.0.4`
  - Mempool: `172.16.0.5`

### Port Configuration

#### Exposed Ports (External Access)
- 80: Mempool.space web interface
- 8333: Bitcoin Core P2P (required for Bitcoin network)

#### Protected Ports (Internal Only)
- 8332: Bitcoin Core RPC
- 50001: Fulcrum Electrum protocol
- 50002: Fulcrum SSL
- 3306: MariaDB

## Container Security

### Common Security Measures
- `no-new-privileges: true` to prevent privilege escalation
- Dropped capabilities except `NET_BIND_SERVICE`
- Health checks for service monitoring
- Restart policy: `on-failure:3`
- Resource limits to prevent DoS

### Service-Specific Security

#### Bitcoin Core
- RPC authentication required
- RPC access restricted to Docker network
- P2P port (8333) exposed for Bitcoin network
- Data directory mounted with proper permissions

#### Fulcrum
- SSL/TLS encryption for all connections
- Self-signed certificates for internal communication
- Electrum protocol ports (50001, 50002) internal only
- Data directory mounted with proper permissions

#### MariaDB
- Strong password authentication
- Database access restricted to Docker network
- Data directory mounted with proper permissions
- Initialization script for secure database setup

#### Mempool
- Web interface (port 80) exposed
- Backend API internal only
- Data directory mounted with proper permissions
- Environment variables for configuration

## Build Process Security

### Dockerfile Security
- Multi-stage builds to minimize image size
- No sensitive data in images
- Minimal base image (Ubuntu 24.04)
- Regular security updates
- Proper user permissions

### Build Script Security
- Prerequisite checks
- Clean build environment
- Verification of built images
- Health check validation
- Log monitoring

## Data Security

### Volume Mounts
- Persistent data directories
- Proper permissions (1000:1000 for services, 999:999 for MariaDB)
- No sensitive data in volumes
- Regular backups recommended

### SSL/TLS Certificates
- Self-signed certificates for internal communication
- Certificate generation during setup
- Certificate rotation support
- Proper permissions on certificate files

## Access Control

### Authentication
- Bitcoin Core RPC: Username/password
- MariaDB: Username/password
- Fulcrum: SSL/TLS certificates
- Mempool: Environment variables

### Network Access
- Internal services: Docker network only
- External services: Specific ports only
- No direct access to internal services
- Proper firewall rules recommended

## Monitoring and Maintenance

### Health Checks
- Bitcoin Core: Blockchain status
- Fulcrum: Service availability
- MariaDB: Database connectivity
- Mempool: API availability

### Logging
- Container logs for all services
- Health check results
- Error monitoring
- Regular log rotation

## Security Best Practices

### Regular Maintenance
1. Update base images regularly
2. Rotate SSL certificates
3. Monitor security advisories
4. Regular backups
5. Log monitoring

### Additional Security Measures
1. Use reverse proxy with SSL
2. Implement rate limiting
3. Regular security audits
4. Monitor system resources
5. Keep documentation updated

## Recommendations

### Additional Security Measures
1. Implement fail2ban for SSH access
2. Set up monitoring alerts
3. Regular security scans
4. Backup encryption
5. Network segmentation

### Monitoring
1. Set up Prometheus metrics
2. Configure Grafana dashboards
3. Implement alerting
4. Regular log analysis
5. Resource monitoring

### Maintenance
1. Regular updates
2. Security patches
3. Certificate rotation
4. Backup verification
5. Performance monitoring 