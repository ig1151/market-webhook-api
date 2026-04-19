import { Router, Request, Response } from 'express';
import Joi from 'joi';
import { v4 as uuidv4 } from 'uuid';
import { getAllWebhooks, getWebhook, saveWebhook, deleteWebhook, getLogs } from '../db/database';

const router = Router();

const createSchema = Joi.object({
  url: Joi.string().uri().required(),
  event_type: Joi.string().valid('news_impact', 'market_signal', 'rebalance_trigger', 'decision_triggered').required(),
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
    risk_tolerance: Joi.string().optional(),
    decision: Joi.string().optional(),
    min_decision_confidence: Joi.number().min(0).max(1).optional()
  }).required()
});

router.post('/', (req: Request, res: Response): void => {
  const { error, value } = createSchema.validate(req.body);
  if (error) {
    res.status(400).json({ error: 'Invalid request', message: error.details[0].message });
    return;
  }

  const id = uuidv4();
  const now = new Date().toISOString();
  const webhook = {
    id,
    url: value.url,
    event_type: value.event_type,
    conditions: value.conditions,
    active: true,
    created_at: now,
    last_triggered: null,
    trigger_count: 0
  };

  saveWebhook(webhook);
  res.status(201).json(webhook);
});

router.get('/', (_req: Request, res: Response): void => {
  const webhooks = getAllWebhooks();
  res.json({ count: webhooks.length, webhooks });
});

router.delete('/:id', (req: Request, res: Response): void => {
  const webhook = getWebhook(req.params.id);
  if (!webhook) {
    res.status(404).json({ error: 'Webhook not found' });
    return;
  }
  deleteWebhook(req.params.id);
  res.json({ success: true, message: 'Webhook deleted' });
});

router.get('/:id/logs', (req: Request, res: Response): void => {
  const webhook = getWebhook(req.params.id);
  if (!webhook) {
    res.status(404).json({ error: 'Webhook not found' });
    return;
  }
  const logs = getLogs(req.params.id);
  res.json({ webhook_id: req.params.id, count: logs.length, logs });
});

export default router;