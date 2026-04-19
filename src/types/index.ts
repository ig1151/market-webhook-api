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
  secret?: string;
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
