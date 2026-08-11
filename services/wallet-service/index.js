const express = require('express');
const pool = require('./config/db');
const { runConsumer } = require('./consumer');

const app = express();
const APP_PORT = process.env.PORT || 3000;

app.get('/', async (req, res) => {
  try {
    // Quick Postgres connection verification check
    await pool.query('SELECT 1');

    const pageTitle = 'Hello World — connected to PostgreSQL!';
    const celebrationText = 'YAY!!';
    const celebrationImage = 'https://media.giphy.com/media/v1.Y2lkPTc5MGI3NjExM3ZleW96b3N5Znd0Ym90bXN6cXd5OHR1c3R5N3Z0Ym90bXN6cXd5JnB0X2luc2lkZT01MTMmY3Rfcz1n/111ebonMs90YLu/giphy.gif';

    const html = `
      <h1>${pageTitle} ${celebrationText}</h1>
      <img src="${celebrationImage}" alt="Celebration">
    `;

    res.send(html);
  } catch (err) {
    const errorMessage = `Hello World — PostgreSQL connection failed: ${err.message}`;
    res.status(500).send(errorMessage);
  }
});

// Liveness and Readiness probes path for Kubernetes
app.get('/health', (req, res) => {
  res.status(200).send({ status: 'UP', timestamp: new Date() });
});

app.listen(APP_PORT, () => {
  console.log(`Server running on http://localhost:${APP_PORT}`);
  
  // Start the Kafka Consumer worker in the background
  runConsumer();
});