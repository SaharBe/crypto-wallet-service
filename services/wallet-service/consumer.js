// `kafka` is needed alongside the consumer for the Admin API (topic creation)
const { consumer, kafka } = require('./config/kafka');
const pool = require('./config/db');

const TOPIC = 'crypto-orders';

// `amount` is handed to Postgres as a decimal string and converted there:
// wallets.balance is NUMERIC(18, 8) (k8s/components/postgres-init-configmap.yaml),
// so a round-trip through a JS float would lose precision.
const AMOUNT_PATTERN = /^\d+(\.\d+)?$/;

const UPSERT_WALLET = `
  INSERT INTO wallets (user_id, currency, balance, updated_at)
  VALUES ($1, $2, $3, CURRENT_TIMESTAMP)
  ON CONFLICT (user_id, currency)
  DO UPDATE SET balance = wallets.balance + $3, updated_at = CURRENT_TIMESTAMP;
`;

// Kept below the consumer's sessionTimeout (KafkaJS default 30s): we
// heartbeat between attempts, and a longer sleep would get this member
// kicked out of wallet-group mid-retry.
const MAX_DB_BACKOFF_MS = 10000;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Helper function to ensure the topic exists before subscribing
async function ensureTopicExists(topicName) {
  const admin = kafka.admin();
  console.log(`🔍 Checking if topic "${topicName}" exists...`);
  try {
    await admin.connect();

    const topics = await admin.listTopics();
    if (!topics.includes(topicName)) {
      console.log(`✨ Topic "${topicName}" not found. Creating it dynamically...`);
      await admin.createTopics({
        topics: [{
          topic: topicName,
          numPartitions: 3,     // 3 partitions as configured previously
          replicationFactor: 1  // Local cluster, single replica is sufficient
        }],
      });
      console.log(`✅ Topic "${topicName}" created successfully!`);
    } else {
      console.log(`✅ Topic "${topicName}" already exists.`);
    }
  } catch (err) {
    console.error(`❌ Failed to check/create topic "${topicName}":`, err.message);
  } finally {
    await admin.disconnect();
  }
}

// Turns a raw Kafka message value into a validated order, or throws if the
// message can never be applied. Anything that would only fail later inside
// Postgres (e.g. a non-numeric amount) has to be rejected here, otherwise
// the DB retry loop in handleMessage() would retry it forever and block
// the partition.
function parseOrder(value) {
  if (!value) {
    throw new Error('empty message value');
  }

  const { userId, coin, amount, action } = JSON.parse(value.toString());

  if ((typeof userId !== 'string' && typeof userId !== 'number') || userId === '') {
    throw new Error(`invalid userId: ${JSON.stringify(userId)}`);
  }
  if (typeof coin !== 'string' || coin === '') {
    throw new Error(`invalid coin: ${JSON.stringify(coin)}`);
  }

  const normalizedAction = typeof action === 'string' ? action.toLowerCase() : action;
  if (normalizedAction !== 'buy' && normalizedAction !== 'sell') {
    throw new Error(`invalid action: ${JSON.stringify(action)}`);
  }

  // order-service forwards amount as the client sent it: number or string
  const amountStr = typeof amount === 'number' ? amount.toFixed(8) : amount;
  if (typeof amountStr !== 'string' || !AMOUNT_PATTERN.test(amountStr) || !(Number(amountStr) > 0)) {
    throw new Error(`invalid amount: ${JSON.stringify(amount)}`);
  }

  return {
    userId: String(userId),
    coin: coin.toUpperCase(),
    amount: amountStr,
    action: normalizedAction,
  };
}

// SQLSTATE class 22 (data exception, e.g. numeric overflow) and 23
// (integrity constraint violation) mean Postgres will reject this order no
// matter how often it's retried. Everything else (connection refused, admin
// shutdown, too many connections, ...) is treated as transient.
function isPermanentDbError(err) {
  return typeof err.code === 'string' && /^2[23][0-9A-Z]{3}$/.test(err.code);
}

async function handleMessage({ partition, message, heartbeat }) {
  const where = `partition ${partition} offset ${message.offset}`;

  let order;
  try {
    order = parseOrder(message.value);
  } catch (err) {
    console.warn(`⚠️ [Skipped] Malformed order at ${where}: ${err.message}`);
    return;
  }

  const balanceChange = order.action === 'buy' ? order.amount : `-${order.amount}`;

  // Returning from eachMessage is what lets KafkaJS commit this offset, so
  // a transient DB failure must never return: keep retrying in place until
  // Postgres is back (PLAT-506). This blocks the partition, which is the
  // point — later orders for the same user must not overtake this one.
  // Consumer lag (kafka_consumergroup_lag) is what makes the stall visible.
  //
  // Delivery is at-least-once: if the UPSERT commits but the reply is lost,
  // the retry applies the order a second time. See PLAT-510 (idempotency).
  for (let attempt = 1; ; attempt += 1) {
    try {
      await pool.query(UPSERT_WALLET, [order.userId, order.coin, balanceChange]);
      console.log(`✅ Applied ${order.action} ${order.amount} ${order.coin} for user ${order.userId} (${where})`);
      return;
    } catch (err) {
      if (isPermanentDbError(err)) {
        console.error(`❌ [Skipped] Postgres rejected order at ${where} (${err.code}): ${err.message}`, order);
        return;
      }

      const backoffMs = Math.min(MAX_DB_BACKOFF_MS, 1000 * 2 ** (attempt - 1));
      console.error(`⏳ Postgres unavailable (attempt ${attempt}), retrying order at ${where} in ${backoffMs}ms:`, err.message);
      await sleep(backoffMs);
      // Not caught on purpose: if a rebalance started meanwhile, this throws,
      // KafkaJS hands the partition over and the new owner re-reads this
      // (uncommitted) offset.
      await heartbeat();
    }
  }
}

async function runConsumer() {
  // KafkaJS restarts a crashed consumer on its own (see the `retry` options
  // in config/kafka.js); this just makes that churn visible. Registered once,
  // outside the setup loop below, so a setup retry doesn't stack listeners.
  consumer.on(consumer.events.CRASH, ({ payload }) => {
    console.error(`⚠️ [Consumer] Crash (recovering): ${payload.error.message}`, {
      restarting: payload.restart
    });
  });

  // config/kafka.js's `retry` only covers low-level broker connection
  // retries. On a fresh cluster this pod can start before Kafka is ready:
  // ensureTopicExists() then gives up silently and subscribe() fails with
  // UNKNOWN_TOPIC_OR_PARTITION. Retrying the whole setup sequence is what
  // keeps the consumer from dying for the rest of the pod's life.
  let attempt = 0;
  while (true) {
    attempt += 1;
    try {
      await ensureTopicExists(TOPIC);

      console.log('🔌 Connecting Kafka Consumer...');
      await consumer.connect();
      console.log('✅ Kafka Consumer connected successfully!');

      await consumer.subscribe({ topic: TOPIC, fromBeginning: true });
      console.log(`👂 Subscribed to topic: ${TOPIC}`);

      await consumer.run({ eachMessage: handleMessage });

      // consumer.run() resolves immediately (it just starts the background
      // fetch loop) — reaching here means setup succeeded, so stop retrying.
      break;
    } catch (error) {
      const backoffMs = Math.min(30000, 1000 * 2 ** Math.min(attempt, 5));
      console.error(`❌ Kafka consumer setup failed (attempt ${attempt}), retrying in ${backoffMs}ms:`, error.message);
      await sleep(backoffMs);
    }
  }
}

module.exports = { runConsumer };
