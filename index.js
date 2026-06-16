const express = require('express');
const { Pool } = require('pg');

const app = express();
const PORT = process.env.PORT || 3000;

const pool = new Pool({
  host: process.env.DB_HOST || 'localhost',
  port: process.env.DB_PORT || 5432,
  database: process.env.DB_NAME || 'mydb',
  user: process.env.DB_USER || 'myuser',
  password: process.env.DB_PASSWORD || 'mypassword',
});

app.get('/', async (req, res) => {
  try {
    await pool.query('SELECT 1');
    res.send('Hello World — connected to PostgreSQL!');
  } catch (err) {
    res.status(500).send(`Hello World — PostgreSQL connection failed: ${err.message}`);
  }
});

app.listen(PORT, () => {
  console.log(`Server running on http://localhost:${PORT}`);
});
