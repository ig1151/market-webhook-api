import axios from 'axios';
import { v4 as uuidv4 } from 'uuid';
import { saveLog, updateWebhookTrigger } from '../db/database';
import { WebhookPayload } from '../types';
import { logger } from '../middleware/logger';

export async function deliverWebhook(
  webhookId: string,
  url: string,
  payload: WebhookPayload,
  attempt = 1,
  secret?: string
): Promise<void> {
  let status: 'delivered' | 'failed' = 'failed';
  let statusCode: number | undefined;

  try {
    const response = await axios.post(url, payload, {
      timeout: 10000,
      headers: {
        'Content-Type': 'application/json',
        'X-Webhook-Event': payload.event,
        ...(secret ? { 'X-Webhook-Secret': secret } : {})
      }
    });
    statusCode = response.status;
    status = 'delivered';
    logger.info({ webhookId, url, event: payload.event }, 'Webhook delivered');
    updateWebhookTrigger(webhookId);
  } catch (err: any) {
    statusCode = err.response?.status;
    logger.warn({ webhookId, url, attempt, error: err.message }, 'Webhook delivery failed');
    if (attempt < 3) {
      const delay = attempt * 2000;
      setTimeout(() => deliverWebhook(webhookId, url, payload, attempt + 1, secret), delay);
    }
  }

  saveLog({
    id: uuidv4(),
    webhook_id: webhookId,
    event_type: payload.event,
    payload,
    status,
    status_code: statusCode ?? null,
    attempt,
    created_at: new Date().toISOString()
  });
}