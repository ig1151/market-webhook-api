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
