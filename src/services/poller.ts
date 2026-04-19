import axios from 'axios';
import cron from 'node-cron';
import { getWebhooksByEventType } from '../db/database';
import { deliverWebhook } from './deliveryEngine';
import { logger } from '../middleware/logger';

async function checkMarketSignals(): Promise<void> {
  const webhooks = getWebhooksByEventType('market_signal');

  for (const webhook of webhooks) {
    const conditions = typeof webhook.conditions === 'string'
      ? JSON.parse(webhook.conditions)
      : webhook.conditions;

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

async function checkRebalanceTriggers(): Promise<void> {
  const webhooks = getWebhooksByEventType('rebalance_trigger');

  for (const webhook of webhooks) {
    const conditions = typeof webhook.conditions === 'string'
      ? JSON.parse(webhook.conditions)
      : webhook.conditions;

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
  cron.schedule('*/5 * * * *', async () => {
    logger.info({}, 'Running webhook poller');
    await Promise.allSettled([
      checkMarketSignals(),
      checkRebalanceTriggers()
    ]);
  });
  logger.info({}, 'Webhook poller started — runs every 5 minutes');
}