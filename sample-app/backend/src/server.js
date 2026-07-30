// acme 샘플 백엔드 — hello world API (Express)
const express = require('express');

const app = express();
const PORT = process.env.PORT || 3000;
const APP_ENV = process.env.APP_ENV || 'local';

app.get('/api/health', (req, res) => res.json({ status: 'ok' }));

app.get('/api/hello', (req, res) =>
  res.json({ message: 'Hello World from backend', env: APP_ENV })
);

app.listen(PORT, () => console.log(`backend listening on :${PORT} (env=${APP_ENV})`));
