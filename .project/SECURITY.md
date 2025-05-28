# Security Documentation

## Network Architecture

### Network Configuration
- Custom bridge network: `bitcoin_network`
- Subnet: 172.16.0.0/16
- Static IP assignments:
  - Bitcoin Core: 172.16.0.2
  - Fulcrum: 172.16.0.3
  - MariaDB: 172.16.0.4
  - Mempool: 172.16.0.5

### Port Configuration

#### Bitcoin Core
- Exposed Ports:
  - 8333: P2P (external) - Required for Bitcoin network communication
- Protected Ports:
  - 8332: RPC (internal only) - Only accessible within Docker network
- RPC Access:
  - Restricted to Docker network (172.16.0.0/12)
  - Requires authentication

#### Fulcrum (Electrum Server)
- Protected Ports:
  - 50001: Electrum protocol (internal only)
  - 50002: SSL (internal only)
- Access:
  - Only accessible from within Docker network
  - SSL/TLS enabled for secure communication

#### MariaDB
- Protected Ports:
  - 3306: Database (internal only)
- Access:
  - Only accessible from within Docker network
  - Requires authentication
  - No external access

#### Mempool.space
- Exposed Ports:
  - 80: Web interface (external)
- Protected Ports:
  - All internal communication ports
- Access:
  - Web interface publicly accessible
  - Backend services only accessible within Docker network

## Container Security

### Common Security Measures
All containers implement:
- `no-new-privileges`: Prevents privilege escalation
- Dropped capabilities: All capabilities removed except `NET_BIND_SERVICE`
- Health checks: Ensures service availability and proper startup order
- Restart policy: `unless-stopped` for automatic recovery

### Service-Specific Security

#### Bitcoin Core
- RPC authentication required
- Network access restricted to Docker network
- Minimal port exposure

#### Fulcrum
- SSL/TLS encryption for all connections
- Internal network access only
- Authentication required for Bitcoin Core connection

#### MariaDB
- Internal network access only
- Strong password authentication
- Optimized security settings in my.cnf

#### Mempool.space
- Public web interface only
- Backend services protected
- Authentication required for Bitcoin Core and database access

## Data Security

### Volume Mounts
- All data directories mounted as volumes
- Proper permissions set (755 for directories)
- Sensitive data isolated in Docker volumes

### SSL/TLS
- Fulcrum SSL certificates automatically generated
- Certificates stored in config directory
- Proper permissions (600 for keys, 644 for certificates)

## Access Control

### Authentication
- Bitcoin Core: RPC authentication required
- MariaDB: Root and user authentication required
- Fulcrum: Bitcoin Core authentication required
- Mempool: Service authentication required

### Network Access
- Inter-container communication enabled
- External access limited to necessary ports
- All internal services protected

## Monitoring and Maintenance

### Health Checks
- Bitcoin Core: Blockchain status monitoring
- Fulcrum: Service availability check
- MariaDB: Database connectivity check
- Mempool: API availability check

### Logging
- All services configured for proper logging
- Log rotation enabled
- Error tracking implemented

## Security Best Practices

1. Regular Updates
   - Keep all containers updated
   - Monitor for security patches
   - Update SSL certificates before expiration

2. Backup Strategy
   - Regular backups of data directories
   - Secure storage of backup data
   - Test restoration procedures

3. Monitoring
   - Regular security audits
   - Monitor for unauthorized access
   - Track system resource usage

4. Incident Response
   - Document security procedures
   - Maintain access logs
   - Regular security reviews

## Recommendations

1. Additional Security Measures
   - Consider implementing a reverse proxy with SSL
   - Add rate limiting for public endpoints
   - Implement IP whitelisting for sensitive services

2. Monitoring
   - Set up external monitoring
   - Implement alerting for security events
   - Regular security scanning

3. Maintenance
   - Regular security updates
   - Certificate rotation
   - Access review and audit 