CREATE DATABASE IF NOT EXISTS mempool;
USE mempool;

-- Create tables for mempool.space
CREATE TABLE IF NOT EXISTS blocks (
    id INT AUTO_INCREMENT PRIMARY KEY,
    height INT NOT NULL,
    hash VARCHAR(64) NOT NULL,
    timestamp INT NOT NULL,
    size INT NOT NULL,
    weight INT NOT NULL,
    tx_count INT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY (height),
    UNIQUE KEY (hash)
);

CREATE TABLE IF NOT EXISTS transactions (
    id INT AUTO_INCREMENT PRIMARY KEY,
    txid VARCHAR(64) NOT NULL,
    block_height INT,
    timestamp INT NOT NULL,
    size INT NOT NULL,
    weight INT NOT NULL,
    fee BIGINT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY (txid),
    FOREIGN KEY (block_height) REFERENCES blocks(height)
); 