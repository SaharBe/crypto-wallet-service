const { Pool } = require('pg');

const DB_CONFIG = {
  host: process.env.DB_HOST || 'localhost',
  port: Number(process.env.DB_PORT) || 5432,
  database: process.env.DB_NAME || 'mydb',
  user: process.env.DB_USER || 'myuser',
  password: process.env.DB_PASSWORD || 'mypassword',
  // Fail fast instead of waiting indefinitely for a connection when Postgres
  // is unreachable: consumer.js's retry loop has to heartbeat Kafka between
  // attempts, and the HTTP API shouldn't hang either.
  connectionTimeoutMillis: 5000,
};

const pool = new Pool(DB_CONFIG);

module.exports = pool;