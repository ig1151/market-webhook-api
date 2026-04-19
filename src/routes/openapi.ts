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
