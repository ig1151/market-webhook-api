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
        }, 1, webhook.secret ?? undefined);
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
        }, 1, webhook.secret ?? undefined);
      }
    } catch (err: any) {
      logger.warn({ webhookId: webhook.id }, 'Rebalance trigger check failed');
    }
  }
}

async function checkDecisionTriggers(): Promise<void> {
  const webhooks = getWebhooksByEventType('decision_triggered');

  for (const webhook of webhooks) {
    const conditions = typeof webhook.conditions === 'string'
      ? JSON.parse(webhook.conditions)
      : webhook.conditions;

    try {
      const url = process.env.UNIFIED_DECISION_API_URL;
      if (!url) continue;
      if (!conditions.portfolio) continue;

      const response = await axios.post(`${url}/v1/decide`, {
        portfolio: conditions.portfolio,
        risk_tolerance: conditions.risk_tolerance ?? 'medium',
        primary_asset: conditions.asset
      }, { timeout: 25000 });

      const data = response.data;

      const decisionMatch = !conditions.decision || data.final_decision === conditions.decision;
      const confidenceMatch = !conditions.min_decision_confidence || data.confidence >= conditions.min_decision_confidence;
      const actionMatch = !conditions.action_bias || data.actions?.some((a: any) => a.action === conditions.action_bias);

      if (decisionMatch && confidenceMatch && actionMatch) {
        await deliverWebhook(webhook.id, webhook.url, {
          event: 'decision_triggered',
          asset: conditions.asset,
          timestamp: new Date().toISOString(),
          data: {
            final_decision: data.final_decision,
            confidence: data.confidence,
            urgency: data.urgency,
            summary: data.summary,
            actions: data.actions,
            signals_used: data.signals_used
          }
        }, 1, webhook.secret ?? undefined);
      }
    } catch (err: any) {
      logger.warn({ webhookId: webhook.id }, 'Decision trigger check failed');
    }
  }
}

export function startPoller(): void {
  cron.schedule('*/5 * * * *', async () => {
    logger.info({}, 'Running webhook poller');
    await Promise.allSettled([
      checkMarketSignals(),
      checkRebalanceTriggers(),
      checkDecisionTriggers()
    ]);
  });
  logger.info({}, 'Webhook poller started — runs every 5 minutes');
}