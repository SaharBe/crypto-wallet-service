const express = require('express');
const { Pool } = require('pg');

const app = express();
const APP_PORT = process.env.PORT || 3000;

const DB_CONFIG = {
  host: process.env.DB_HOST || 'localhost',
  port: Number(process.env.DB_PORT) || 5432,
  database: process.env.DB_NAME || 'mydb',
  user: process.env.DB_USER || 'myuser',
  password: process.env.DB_PASSWORD || 'mypassword',
};

const pool = new Pool(DB_CONFIG);

app.get('/', async (req, res) => {
  try {
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

app.listen(APP_PORT, () => {
  console.log(`Server running on http://localhost:${APP_PORT}`);
});
