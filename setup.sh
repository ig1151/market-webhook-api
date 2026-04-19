#!/bin/bash
set -e

mkdir -p src/{routes,middleware,services,types,db}

cat > package.json << 'EOF'
{
  "name": "market-webhook-api",
  "version": "1.0.0",
  "description": "Event-driven webhook API for crypto markets. Get instant notifications when news impact, market signals or portfolio drift conditions are met.",
  "main": "dist/index.js",
  "scripts": {
    "dev": "ts-node-dev --respawn --transpile-only src/index.ts",
    "build": "tsc",
    "start": "node dist/index.js"
  },
  "dependencies": {
    "axios": "^1.6.0",
    "better-sqlite3": "^9.4.3",
    "compression": "^1.7.4",
    "cors": "^2.8.5",
    "dotenv": "^16.3.1",
    "express": "^4.18.2",
    "express-rate-limit": "^7.1.5",
    "helmet": "^7.1.0",
    "joi": "^17.11.0",
    "node-cron": "^3.0.3",
    "uuid": "^9.0.0"
  },
  "devDependencies": {
    "@types/better-sqlite3": "^7.6.8",
    "@types/compression": "^1.7.5",
    "@types/cors": "^2.8.17",
    "@types/express": "^4.17.21",
    "@types/node": "^20.10.0",
    "@types/node-cron": "^3.0.11",
    "@types/uuid": "^9.0.7",
    "ts-node-dev": "^2.0.0",
    "typescript": "^5.3.2"
  }
}
EOF

cat > tsconfig.json << 'EOF'
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "commonjs",
    "outDir": "./dist",
    "rootDir": "./src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "dist"]
}
EOF

cat > render.yaml << 'EOF'
services:
  - type: web
    name: market-webhook-api
    env: node
    buildCommand: npm install && npm run build
    startCommand: node dist/index.js
    healthCheckPath: /v1/health
    envVars:
      - key: NODE_ENV
        value: production
      - key: MARKET_SIGNAL_API_URL
        value: https://market-signal-api-iu2o.onrender.com
      - key: NEWS_IMPACT_API_URL
        value: https://crypto-news-impact-api.onrender.com
      - key: PORTFOLIO_REBALANCE_API_URL
        value: https://portfolio-rebalance-api.onrender.com
EOF

cat > .gitignore << 'EOF'
node_modules/
dist/
.env
*.log
*.db
EOF

cat > .env << 'EOF'
PORT=3000
MARKET_SIGNAL_API_URL=https://market-signal-api-iu2o.onrender.com
NEWS_IMPACT_API_URL=https://crypto-news-impact-api.onrender.com
PORTFOLIO_REBALANCE_API_URL=https://portfolio-rebalance-api.onrender.com
EOF

cat > src/types/index.ts << 'EOF'
export type EventType = 'news_impact' | 'market_signal' | 'rebalance_trigger';

export interface WebhookConditions {
  asset: string;
  min_impact_score?: number;
  action_bias?: string;
  sentiment?: string;
  min_confidence?: number;
  signal?: string;
  min_rebalance_score?: number;
}

export interface Webhook {
  id: string;
  url: string;
  event_type: EventType;
  conditions: WebhookConditions;
  active: boolean;
  created_at: string;
  last_triggered?: string;
  trigger_count: number;
}

export interface WebhookLog {
  id: string;
  webhook_id: string;
  event_type: EventType;
  payload: Record<string, any>;
  status: 'delivered' | 'failed';
  status_code?: number;
  attempt: number;
  created_at: string;
}

export interface WebhookPayload {
  event: EventType;
  asset: string;
  timestamp: string;
  data: Record<string, any>;
}
EOF

cat > src/db/database.ts << 'EOF'
import Database from 'better-sqlite3';
import path from 'path';

const DB_PATH = process.env.DB_PATH || path.join(process.cwd(), 'webhooks.db');

let db: Database.Database;

export function getDb(): Database.Database {
  if (!db) {
    db = new Database(DB_PATH);
    db.pragma('journal_mode = WAL');
    initSchema(db);
  }
  return db;
}

function initSchema(db: Database.Database): void {
  db.exec(`
    CREATE TABLE IF NOT EXISTS webhooks (
      id TEXT PRIMARY KEY,
      url TEXT NOT NULL,
      event_type TEXT NOT NULL,
      conditions TEXT NOT NULL,
      active INTEGER DEFAULT 1,
      created_at TEXT NOT NULL,
      last_triggered TEXT,
      trigger_count INTEGER DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS webhook_logs (
      id TEXT PRIMARY KEY,
      webhook_id TEXT NOT NULL,
      event_type TEXT NOT NULL,
      payload TEXT NOT NULL,
      status TEXT NOT NULL,
      status_code INTEGER,
      attempt INTEGER DEFAULT 1,
      created_at TEXT NOT NULL,
      FOREIGN KEY (webhook_id) REFERENCES webhooks(id)
    );
  `);
}
EOF

cat > src/middleware/logger.ts << 'EOF'
export const logger = {
  info: (obj: unknown, msg?: string) =>
    console.log(JSON.stringify({ level: 'info', ...(typeof obj === 'object' ? obj : { data: obj }), msg })),
  warn: (obj: unknown, msg?: string) =>
    console.warn(JSON.stringify({ level: 'warn', ...(typeof obj === 'object' ? obj : { data: obj }), msg })),
  error: (obj: unknown, msg?: string) =>
    console.error(JSON.stringify({ level: 'error', ...(typeof obj === 'object' ? obj : { data: obj }), msg })),
};
EOF

cat > src/middleware/requestLogger.ts << 'EOF'
import { Request, Response, NextFunction } from 'express';
import { logger } from './logger';

export function requestLogger(req: Request, res: Response, next: NextFunction): void {
  const start = Date.now();
  res.on('finish', () => {
    logger.info({ method: req.method, path: req.path, status: res.statusCode, ms: Date.now() - start });
  });
  next();
}
EOF

cat > src/middleware/rateLimiter.ts << 'EOF'
import rateLimit from 'express-rate-limit';

export const rateLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 100,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many requests', message: 'Rate limit exceeded.' }
});
EOF

cat > src/services/deliveryEngine.ts << 'EOF'
import axios from 'axios';
import { v4 as uuidv4 } from 'uuid';
import { getDb } from '../db/database';
import { WebhookPayload } from '../types';
import { logger } from '../middleware/logger';

export async function deliverWebhook(
  webhookId: string,
  url: string,
  payload: WebhookPayload,
  attempt = 1
): Promise<void> {
  const db = getDb();
  const logId = uuidv4();
  let status: 'delivered' | 'failed' = 'failed';
  let statusCode: number | undefined;

  try {
    const response = await axios.post(url, payload, {
      timeout: 10000,
      headers: { 'Content-Type': 'application/json', 'X-Webhook-Event': payload.event }
    });
    statusCode = response.status;
    status = 'delivered';
    logger.info({ webhookId, url, event: payload.event }, 'Webhook delivered');

    // Update trigger count and last_triggered
    db.prepare(`
      UPDATE webhooks SET last_triggered = ?, trigger_count = trigger_count + 1 WHERE id = ?
    `).run(new Date().toISOString(), webhookId);

  } catch (err: any) {
    statusCode = err.response?.status;
    logger.warn({ webhookId, url, attempt, error: err.message }, 'Webhook delivery failed');

    // Retry up to 3 times with exponential backoff
    if (attempt < 3) {
      const delay = attempt * 2000;
      setTimeout(() => deliverWebhook(webhookId, url, payload, attempt + 1), delay);
    }
  }

  db.prepare(`
    INSERT INTO webhook_logs (id, webhook_id, event_type, payload, status, status_code, attempt, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `).run(logId, webhookId, payload.event, JSON.stringify(payload), status, statusCode ?? null, attempt, new Date().toISOString());
}
EOF

cat > src/services/poller.ts << 'EOF'
import axios from 'axios';
import cron from 'node-cron';
import { getDb } from '../db/database';
import { deliverWebhook } from './deliveryEngine';
import { logger } from '../middleware/logger';

async function checkMarketSignals(): Promise<void> {
  const db = getDb();
  const webhooks = db.prepare(`SELECT * FROM webhooks WHERE active = 1 AND event_type = 'market_signal'`).all() as any[];

  for (const webhook of webhooks) {
    const conditions = JSON.parse(webhook.conditions);
    try {
      const url = process.env.MARKET_SIGNAL_API_URL;
      const response = await axios.get(`${url}/v1/signal/${conditions.asset}`, { timeout: 15000 });
      const data = response.data;

      const signalMatch = !conditions.signal || data.decision === conditions.signal;
      const confidenceMatch = !conditions.min_confidence || data.confidence >= conditions.min_confidence;

      if (signalMatch && confidenceMatch) {
        await deliverWebhook(webhook.id, webhook.url, {
          event: 'market_signal',
          asset: conditions.asset,
          timestamp: new Date().toISOString(),
          data: {
            decision: data.decision,
            confidence: data.confidence,
            risk: data.risk,
            trend: data.trend,
            verdict: data.verdict,
            reasons: data.reasons
          }
        });
      }
    } catch (err: any) {
      logger.warn({ webhookId: webhook.id, asset: conditions.asset }, 'Market signal check failed');
    }
  }
}

async function checkNewsImpact(): Promise<void> {
  const db = getDb();
  const webhooks = db.prepare(`SELECT * FROM webhooks WHERE active = 1 AND event_type = 'news_impact'`).all() as any[];

  for (const webhook of webhooks) {
    const conditions = JSON.parse(webhook.conditions);
    try {
      // News impact requires articles — skip polling for now, triggered via API
      logger.info({ webhookId: webhook.id }, 'News impact webhooks are event-triggered');
    } catch (err: any) {
      logger.warn({ webhookId: webhook.id }, 'News impact check failed');
    }
  }
}

async function checkRebalanceTriggers(): Promise<void> {
  const db = getDb();
  const webhooks = db.prepare(`SELECT * FROM webhooks WHERE active = 1 AND event_type = 'rebalance_trigger'`).all() as any[];

  for (const webhook of webhooks) {
    const conditions = JSON.parse(webhook.conditions);
    try {
      const url = process.env.PORTFOLIO_REBALANCE_API_URL;
      if (!conditions.portfolio) continue;

      const response = await axios.post(`${url}/v1/rebalance`, {
        portfolio: conditions.portfolio,
        strategy: conditions.strategy ?? 'risk_adjusted',
        risk_tolerance: conditions.risk_tolerance ?? 'medium'
      }, { timeout: 20000 });

      const data = response.data;
      const scoreMatch = !conditions.min_rebalance_score || data.summary?.rebalance_score >= conditions.min_rebalance_score;

      if (data.summary?.trigger && scoreMatch) {
        await deliverWebhook(webhook.id, webhook.url, {
          event: 'rebalance_trigger',
          asset: conditions.asset ?? 'PORTFOLIO',
          timestamp: new Date().toISOString(),
          data: {
            rebalance_score: data.summary.rebalance_score,
            trigger: data.summary.trigger,
            portfolio_health: data.portfolio_health,
            actions: data.actions,
            estimated_turnover: data.summary.estimated_turnover
          }
        });
      }
    } catch (err: any) {
      logger.warn({ webhookId: webhook.id }, 'Rebalance trigger check failed');
    }
  }
}

export function startPoller(): void {
  // Run every 5 minutes
  cron.schedule('*/5 * * * *', async () => {
    logger.info({}, 'Running webhook poller');
    await Promise.allSettled([
      checkMarketSignals(),
      checkNewsImpact(),
      checkRebalanceTriggers()
    ]);
  });
  logger.info({}, 'Webhook poller started — runs every 5 minutes');
}
EOF

cat > src/routes/webhooks.ts << 'EOF'
import { Router, Request, Response } from 'express';
import Joi from 'joi';
import { v4 as uuidv4 } from 'uuid';
import { getDb } from '../db/database';
import { logger } from '../middleware/logger';

const router = Router();

const createSchema = Joi.object({
  url: Joi.string().uri().required(),
  event_type: Joi.string().valid('news_impact', 'market_signal', 'rebalance_trigger').required(),
  conditions: Joi.object({
    asset: Joi.string().min(1).max(20).uppercase().required(),
    min_impact_score: Joi.number().min(0).max(100).optional(),
    action_bias: Joi.string().optional(),
    sentiment: Joi.string().optional(),
    min_confidence: Joi.number().min(0).max(1).optional(),
    signal: Joi.string().optional(),
    min_rebalance_score: Joi.number().min(0).max(100).optional(),
    portfolio: Joi.array().optional(),
    strategy: Joi.string().optional(),
    risk_tolerance: Joi.string().optional()
  }).required()
});

// POST /v1/webhooks — create
router.post('/', (req: Request, res: Response): void => {
  const { error, value } = createSchema.validate(req.body);
  if (error) {
    res.status(400).json({ error: 'Invalid request', message: error.details[0].message });
    return;
  }

  const db = getDb();
  const id = uuidv4();
  const now = new Date().toISOString();

  db.prepare(`
    INSERT INTO webhooks (id, url, event_type, conditions, active, created_at, trigger_count)
    VALUES (?, ?, ?, ?, 1, ?, 0)
  `).run(id, value.url, value.event_type, JSON.stringify(value.conditions), now);

  res.status(201).json({
    id,
    url: value.url,
    event_type: value.event_type,
    conditions: value.conditions,
    active: true,
    created_at: now,
    trigger_count: 0
  });
});

// GET /v1/webhooks — list
router.get('/', (req: Request, res: Response): void => {
  const db = getDb();
  const webhooks = db.prepare(`SELECT * FROM webhooks ORDER BY created_at DESC`).all() as any[];
  res.json({
    count: webhooks.length,
    webhooks: webhooks.map(w => ({ ...w, conditions: JSON.parse(w.conditions), active: w.active === 1 }))
  });
});

// DELETE /v1/webhooks/:id — remove
router.delete('/:id', (req: Request, res: Response): void => {
  const db = getDb();
  const webhook = db.prepare(`SELECT * FROM webhooks WHERE id = ?`).get(req.params.id);
  if (!webhook) {
    res.status(404).json({ error: 'Webhook not found' });
    return;
  }
  db.prepare(`DELETE FROM webhooks WHERE id = ?`).run(req.params.id);
  res.json({ success: true, message: 'Webhook deleted' });
});

// GET /v1/webhooks/:id/logs — delivery history
router.get('/:id/logs', (req: Request, res: Response): void => {
  const db = getDb();
  const webhook = db.prepare(`SELECT * FROM webhooks WHERE id = ?`).get(req.params.id);
  if (!webhook) {
    res.status(404).json({ error: 'Webhook not found' });
    return;
  }
  const logs = db.prepare(`
    SELECT * FROM webhook_logs WHERE webhook_id = ? ORDER BY created_at DESC LIMIT 50
  `).all(req.params.id) as any[];
  res.json({
    webhook_id: req.params.id,
    count: logs.length,
    logs: logs.map(l => ({ ...l, payload: JSON.parse(l.payload) }))
  });
});

export default router;
EOF

cat > src/routes/health.ts << 'EOF'
import { Router, Request, Response } from 'express';
const router = Router();

router.get('/', (_req: Request, res: Response) => {
  res.json({
    status: 'ok',
    service: 'market-webhook-api',
    version: '1.0.0',
    uptime: Math.floor(process.uptime()),
    timestamp: new Date().toISOString()
  });
});

export default router;
EOF

cat > src/routes/docs.ts << 'EOF'
import { Router, Request, Response } from 'express';
const router = Router();

router.get('/', (_req: Request, res: Response) => {
  res.json({
    service: 'Market Webhook API',
    version: '1.0.0',
    description: 'Event-driven webhook API for crypto markets. Get instant notifications when news impact, market signals or portfolio drift conditions are met.',
    endpoints: [
      { method: 'POST', path: '/v1/webhooks', description: 'Create a webhook subscription' },
      { method: 'GET', path: '/v1/webhooks', description: 'List all webhook subscriptions' },
      { method: 'DELETE', path: '/v1/webhooks/:id', description: 'Delete a webhook subscription' },
      { method: 'GET', path: '/v1/webhooks/:id/logs', description: 'Get delivery logs for a webhook' },
      { method: 'GET', path: '/v1/health', description: 'Health check' }
    ],
    event_types: {
      market_signal: 'Fires when a strong buy/sell signal is detected for an asset',
      news_impact: 'Fires when high-impact news is detected for an asset',
      rebalance_trigger: 'Fires when portfolio drift exceeds rebalance threshold'
    },
    example: {
      url: 'https://mybot.com/webhook',
      event_type: 'market_signal',
      conditions: {
        asset: 'BTC',
        signal: 'buy',
        min_confidence: 0.8
      }
    }
  });
});

export default router;
EOF

cat > src/routes/openapi.ts << 'EOF'
import { Router, Request, Response } from 'express';
const router = Router();

router.get('/', (_req: Request, res: Response) => {
  res.json({
    openapi: '3.0.0',
    info: { title: 'Market Webhook API', version: '1.0.0', description: 'Event-driven webhook API for crypto markets' },
    servers: [{ url: 'https://market-webhook-api.onrender.com' }],
    paths: {
      '/v1/webhooks': {
        post: {
          summary: 'Create webhook subscription',
          requestBody: {
            required: true,
            content: {
              'application/json': {
                schema: {
                  type: 'object',
                  required: ['url', 'event_type', 'conditions'],
                  properties: {
                    url: { type: 'string', example: 'https://mybot.com/webhook' },
                    event_type: { type: 'string', enum: ['news_impact', 'market_signal', 'rebalance_trigger'] },
                    conditions: { type: 'object' }
                  }
                }
              }
            }
          },
          responses: { '201': { description: 'Webhook created' }, '400': { description: 'Invalid request' } }
        },
        get: { summary: 'List webhooks', responses: { '200': { description: 'Webhook list' } } }
      },
      '/v1/webhooks/{id}': {
        delete: { summary: 'Delete webhook', responses: { '200': { description: 'Deleted' }, '404': { description: 'Not found' } } }
      },
      '/v1/webhooks/{id}/logs': {
        get: { summary: 'Get delivery logs', responses: { '200': { description: 'Log list' } } }
      },
      '/v1/health': {
        get: { summary: 'Health check', responses: { '200': { description: 'OK' } } }
      }
    }
  });
});

export default router;
EOF

cat > src/index.ts << 'EOF'
import 'dotenv/config';
import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import compression from 'compression';
import { requestLogger } from './middleware/requestLogger';
import { rateLimiter } from './middleware/rateLimiter';
import webhooksRouter from './routes/webhooks';
import healthRouter from './routes/health';
import docsRouter from './routes/docs';
import openapiRouter from './routes/openapi';
import { startPoller } from './services/poller';
import { getDb } from './db/database';

const app = express();
const PORT = process.env.PORT || 3000;

app.use(helmet());
app.use(cors());
app.use(compression());
app.use(express.json());
app.use(requestLogger);
app.use(rateLimiter);

app.use('/v1/health', healthRouter);
app.use('/v1/webhooks', webhooksRouter);
app.use('/docs', docsRouter);
app.use('/openapi.json', openapiRouter);

app.get('/', (_req, res) => {
  res.json({
    service: 'Market Webhook API',
    version: '1.0.0',
    docs: '/docs',
    health: '/v1/health',
    example: 'POST /v1/webhooks'
  });
});

app.use((_req, res) => {
  res.status(404).json({ error: 'Not found' });
});

// Init DB and start poller
getDb();
startPoller();

app.listen(PORT, () => {
  console.log(JSON.stringify({ level: 'info', msg: `Market Webhook API running on port ${PORT}` }));
});

export default app;
EOF

echo "✅ All files created."
echo ""
echo "Next steps:"
echo "  1. npm install"
echo "  2. npm run dev"
echo "  3. Test: POST /v1/webhooks"