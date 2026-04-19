import fs from 'fs';
import path from 'path';

const DB_PATH = process.env.DB_PATH || path.join(process.cwd(), 'data.json');

interface DbData {
  webhooks: Record<string, any>;
  logs: Record<string, any[]>;
}

function loadData(): DbData {
  if (!fs.existsSync(DB_PATH)) {
    const empty: DbData = { webhooks: {}, logs: {} };
    fs.writeFileSync(DB_PATH, JSON.stringify(empty, null, 2));
    return empty;
  }
  return JSON.parse(fs.readFileSync(DB_PATH, 'utf8'));
}

function saveData(data: DbData): void {
  fs.writeFileSync(DB_PATH, JSON.stringify(data, null, 2));
}

export function getAllWebhooks(): any[] {
  return Object.values(loadData().webhooks);
}

export function getWebhook(id: string): any | null {
  return loadData().webhooks[id] ?? null;
}

export function saveWebhook(webhook: any): void {
  const data = loadData();
  data.webhooks[webhook.id] = webhook;
  saveData(data);
}

export function deleteWebhook(id: string): void {
  const data = loadData();
  delete data.webhooks[id];
  delete data.logs[id];
  saveData(data);
}

export function getWebhooksByEventType(eventType: string): any[] {
  return Object.values(loadData().webhooks).filter((w: any) => w.event_type === eventType && w.active);
}

export function saveLog(log: any): void {
  const data = loadData();
  if (!data.logs[log.webhook_id]) data.logs[log.webhook_id] = [];
  data.logs[log.webhook_id].unshift(log);
  // Keep only last 50 logs per webhook
  data.logs[log.webhook_id] = data.logs[log.webhook_id].slice(0, 50);
  saveData(data);
}

export function getLogs(webhookId: string): any[] {
  return loadData().logs[webhookId] ?? [];
}

export function updateWebhookTrigger(id: string): void {
  const data = loadData();
  if (data.webhooks[id]) {
    data.webhooks[id].last_triggered = new Date().toISOString();
    data.webhooks[id].trigger_count = (data.webhooks[id].trigger_count ?? 0) + 1;
    saveData(data);
  }
}