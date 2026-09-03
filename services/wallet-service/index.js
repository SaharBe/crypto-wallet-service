const express = require('express');
const pool = require('./config/db');
const { runConsumer } = require('./consumer');

const app = express();
app.use(express.json());

const APP_PORT = process.env.PORT || 3000;

// GET / - Structured JSON endpoint for Wallet API
app.get('/', async (req, res) => {
  try {
    await pool.query('SELECT 1');
    return res.status(200).json({
      service: 'wallet-service',
      status: 'healthy',
      database: 'connected',
      message: 'Crypto Wallet Service API is operational'
    });
  } catch (err) {
    return res.status(500).json({
      service: 'wallet-service',
      status: 'degraded',
      database: 'disconnected',
      error: err.message
    });
  }
});

// GET /balance/:userId - Fetch user wallet balance
app.get('/balance/:userId', async (req, res) => {
  const { userId } = req.params;
  try {
    const result = await pool.query(
      'SELECT coin, amount FROM wallet_balances WHERE user_id = $1',
      [userId]
    );
    return res.status(200).json({
      userId,
      balances: result.rows
    });
  } catch (err) {
    console.error('Error fetching balance:', err);
    return res.status(500).json({ error: 'Failed to fetch wallet balance' });
  }
});

// Liveness and Readiness probes for Kubernetes
app.get('/health', (req, res) => {
  res.status(200).json({ status: 'UP', timestamp: new Date().toISOString() });
});

app.listen(APP_PORT, () => {
  console.log(`Wallet Service running on port ${APP_PORT}`);
  runConsumer();
});