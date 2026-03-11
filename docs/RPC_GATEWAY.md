# RPC Gateway

## Overview

The RPC gateway exposes your Bitcoin Core JSON-RPC interface over HTTP(S) with API key authentication, per-key rate limiting, method whitelisting, and per-network routing. It runs as a Lua module inside the OpenResty reverse proxy — no additional containers needed.

When enabled (`RPC_ENDPOINT_ENABLED=true` in `node.conf`), the gateway accepts requests at:

```
POST /v2/{api-key}[/{network}]
POST /v2/ + X-API-Key header
```

### Defense in Depth

The RPC gateway uses two layers of protection:

```
Internet
  │
  │ HTTPS (port 3000 or configured RPC port)
  ▼
┌───────────────────────────────────────────────┐
│  OpenResty (Lua)                              │
│                                               │
│  1. TLS termination                           │
│  2. API key validation (URL path or header)   │
│  3. JSON-RPC body parsing (cjson)             │
│  4. Method whitelist check                    │
│  5. Per-key rate limiting (lua-resty-limit)   │
│  6. CORS headers                              │
└──────────────────┬────────────────────────────┘
                   │ HTTP (internal Docker network)
                   ▼
┌───────────────────────────────────────────────┐
│  Bitcoin Core (internal only)                 │
│                                               │
│  - rpcwhitelist per RPC user (gateway user)   │
│  - rpcallowip=172.20.0.0/24 (docker only)    │
│  - rpcwhitelistdefault=0                      │
└───────────────────────────────────────────────┘
```

Even if the Lua layer is bypassed, Bitcoin Core itself enforces a separate whitelist on the gateway's RPC user. Internal services (Electrs, Mempool API) use a different RPC user with full access.

---

## Enabling the RPC Gateway

### During Initial Setup

The wizard (`wizard.sh`) includes an RPC endpoint section. Select **yes** when prompted:

```
──── RPC Web Endpoint ────
Enable the Bitcoin RPC web endpoint? [y/N]: y
```

The wizard configures:
- Method profile (read-only / standard / full)
- Rate limit (requests per minute, default: 60)
- RPC port (default: 3000)
- Generates a default API key (`mk_live_` + 32 hex chars)
- Creates a separate gateway RPC user for Bitcoin Core

### After Initial Setup

Set `RPC_ENDPOINT_ENABLED=true` in `node.conf` and regenerate:

```bash
# Edit node.conf
sed -i 's/RPC_ENDPOINT_ENABLED=false/RPC_ENDPOINT_ENABLED=true/' node.conf

# Regenerate all config files
./scripts/setup/generate-config.sh

# Restart OpenResty to load the new config
docker compose restart openresty
```

---

## API Key Management

API keys are stored in `config/openresty/api-keys.json` (host filesystem). OpenResty reads this file on each request, so changes take effect after an `nginx -s reload` — which the management scripts handle automatically.

### Add a Key

```bash
./scripts/rpc/add-key.sh --name "my-app" --rate-limit 120

# Output:
#   Key:        mk_live_a1b2c3d4e5f6...
#   Name:       my-app
#   Rate Limit: 120 req/min
```

Options:

| Flag | Default | Description |
|------|---------|-------------|
| `--name NAME` | `unnamed` | Friendly label for the key |
| `--rate-limit N` | `60` | Requests per minute allowed |
| `--profile PROFILE` | *(none)* | Informational tag stored in JSON (e.g., `read-only`) |

The generated key format is `mk_live_` followed by 32 random hex characters. Keys are immediately active after OpenResty reload.

### List Keys

```bash
# Table format (keys masked)
./scripts/rpc/list-keys.sh

# JSON format (includes full keys)
./scripts/rpc/list-keys.sh --json
```

Table output masks keys as `mk_live_...last4` for safe display.

### Revoke a Key

```bash
# Disable the key (soft revoke — key stays in JSON with enabled=false)
./scripts/rpc/revoke-key.sh mk_live_a1b2c3d4e5f6...

# Delete the key entirely
./scripts/rpc/revoke-key.sh mk_live_a1b2c3d4e5f6... --delete
```

Disabled keys return a `403 Forbidden` response. Deleted keys return `403 Invalid API key`.

### Key Storage Format

`config/openresty/api-keys.json`:

```json
{
  "mk_live_a1b2c3d4e5f6789012345678deadbeef": {
    "name": "my-app",
    "enabled": true,
    "rate_limit": 120
  },
  "mk_live_00112233445566778899aabbccddeeff": {
    "name": "monitoring",
    "enabled": true,
    "rate_limit": 30
  }
}
```

---

## Making RPC Requests

### Authentication Methods

**Path-based** (key in URL):

```bash
curl -X POST http://your-server:3000/v2/mk_live_YOUR_KEY \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo","params":[]}'
```

**Header-based** (key in `X-API-Key`):

```bash
curl -X POST http://your-server:3000/v2/default \
  -H "Content-Type: application/json" \
  -H "X-API-Key: mk_live_YOUR_KEY" \
  -d '{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo","params":[]}'
```

### Per-Network Routing

Append the network name to route to a specific Bitcoin Core instance:

```bash
# Mainnet (default when no network specified)
curl -X POST http://your-server:3000/v2/YOUR_KEY/mainnet \
  -d '{"jsonrpc":"2.0","id":1,"method":"getblockcount","params":[]}'

# Signet
curl -X POST http://your-server:3000/v2/YOUR_KEY/signet \
  -d '{"jsonrpc":"2.0","id":1,"method":"getblockcount","params":[]}'

# Testnet
curl -X POST http://your-server:3000/v2/YOUR_KEY/testnet \
  -d '{"jsonrpc":"2.0","id":1,"method":"getblockcount","params":[]}'
```

### Testing with the Built-in Script

```bash
# Basic test (uses first key in api-keys.json, calls getblockchaininfo)
./scripts/rpc/test-endpoint.sh

# Specific method
./scripts/rpc/test-endpoint.sh --method getblockcount

# Specific network
./scripts/rpc/test-endpoint.sh --method getblockcount --network signet

# Specific key with header auth
./scripts/rpc/test-endpoint.sh --key mk_live_YOUR_KEY --header

# Custom host/port (e.g., testing remotely)
./scripts/rpc/test-endpoint.sh --host mempool.example.com --port 443
```

---

## Method Whitelist Profiles

The wizard lets you choose a method profile that controls which Bitcoin Core RPC methods are allowed through the gateway. This whitelist is enforced at both the Lua layer (OpenResty) and the Bitcoin Core layer (`rpcwhitelist`).

### read-only

Safe query methods only. Suitable for public or untrusted access.

| Method | Description |
|--------|-------------|
| `getblockchaininfo` | Chain state summary |
| `getblock` | Block data by hash |
| `getblockcount` | Current block height |
| `getblockhash` | Block hash by height |
| `getblockheader` | Block header by hash |
| `getblockstats` | Per-block statistics |
| `getchaintips` | Known chain tips |
| `getdifficulty` | Current difficulty |
| `getmempoolinfo` | Mempool summary |
| `getrawmempool` | Mempool transaction list |
| `getmempoolentry` | Single mempool entry |
| `gettxout` | Unspent output data |
| `gettxoutsetinfo` | UTXO set statistics |
| `getrawtransaction` | Raw transaction data |
| `decoderawtransaction` | Decode raw tx hex |
| `decodescript` | Decode script hex |
| `getnetworkinfo` | Network state |
| `getpeerinfo` | Connected peers |
| `getconnectioncount` | Peer count |
| `getnettotals` | Network traffic stats |
| `getmininginfo` | Mining state |
| `getnetworkhashps` | Network hash rate |
| `estimatesmartfee` | Fee estimation |
| `validateaddress` | Address validation |
| `getindexinfo` | Index status |
| `getblockfilter` | BIP 157 block filter |
| `getbestblockhash` | Best block hash |

### standard

Everything in read-only, plus transaction broadcast. Suitable for application integration.

| Additional Method | Description |
|-------------------|-------------|
| `sendrawtransaction` | Broadcast a signed transaction |
| `testmempoolaccept` | Validate a transaction without broadcasting |

### full

Everything in standard, plus wallet and advanced methods. For trusted/admin use only.

| Additional Method | Description |
|-------------------|-------------|
| `getbalance` | Wallet balance |
| `gettransaction` | Wallet transaction details |
| `listtransactions` | Wallet transaction history |
| `listunspent` | Wallet UTXOs |
| `createrawtransaction` | Build unsigned transaction |
| `signrawtransactionwithkey` | Sign transaction with provided keys |
| `getaddressinfo` | Address metadata |
| `deriveaddresses` | Derive addresses from descriptor |
| `getdescriptorinfo` | Descriptor metadata |
| `submitblock` | Submit a mined block |
| `submitheader` | Submit a block header |
| `getblocktemplate` | Mining block template |
| `getrawchangeaddress` | New change address |
| `getnewaddress` | New receiving address |
| `walletprocesspsbt` | Process PSBT |
| `analyzepsbt` | Analyze PSBT |
| `combinepsbt` | Combine PSBTs |
| `decodepsbt` | Decode PSBT |
| `createpsbt` | Create PSBT |

### Always Blocked

These methods are blocked in all profiles, including `full`:

| Method | Reason |
|--------|--------|
| `stop` | Shuts down Bitcoin Core |
| `dumpprivkey` | Exports private keys |
| `dumpwallet` | Exports entire wallet |
| `importprivkey` | Imports keys (modifies wallet) |
| `invalidateblock` | Forces chain reorganization |
| `pruneblockchain` | Deletes block data |
| `generateblock` | Regtest mining (not applicable) |
| `generatetoaddress` | Regtest mining (not applicable) |

---

## Rate Limiting

Rate limits are per-key, specified in requests per minute. The Lua rate limiter (`lua-resty-limit-req`) converts this to a per-second rate with a burst allowance of 2x the per-second rate.

Example: a key with `rate_limit: 120` allows:
- Sustained rate: 2 requests/second
- Burst: up to 4 requests/second (brief spike)
- After burst: excess requests are delayed or rejected with HTTP 429

### Rate Limit Response

When a key exceeds its rate limit:

```json
{
  "jsonrpc": "2.0",
  "error": {
    "code": -32005,
    "message": "Rate limit exceeded: 120 requests/minute"
  },
  "id": null
}
```

HTTP status: `429 Too Many Requests`

---

## Error Responses

All errors follow JSON-RPC 2.0 format:

| HTTP Status | Code | Message | Cause |
|-------------|------|---------|-------|
| 401 | -32001 | Missing API key | No key in URL path or header |
| 403 | -32002 | Invalid API key | Key not found in api-keys.json |
| 403 | -32002 | API key is disabled | Key exists but `enabled: false` |
| 403 | -32601 | Method not allowed: X | Method not in whitelist profile |
| 400 | -32700 | Parse error: empty request body | No POST body |
| 400 | -32700 | Parse error: invalid JSON-RPC request | Malformed JSON or missing `method` |
| 429 | -32005 | Rate limit exceeded | Per-key rate limit hit |
| 500 | -32603 | Internal error | Failed to load api-keys.json |

---

## CORS

The RPC gateway includes CORS headers for browser-based access. The OpenResty configuration adds:

- `Access-Control-Allow-Origin` based on the configured domain
- `Access-Control-Allow-Methods: POST, OPTIONS`
- `Access-Control-Allow-Headers: Content-Type, X-API-Key`
- OPTIONS preflight requests return 204

---

## Script Reference

| Script | Purpose |
|--------|---------|
| `scripts/rpc/add-key.sh` | Generate and add a new API key |
| `scripts/rpc/list-keys.sh` | List all keys (table or JSON) |
| `scripts/rpc/revoke-key.sh` | Disable or delete an API key |
| `scripts/rpc/test-endpoint.sh` | Test the RPC endpoint |

All scripts support `--help` for full usage information.
