// 1. Import kafka instance alongside the consumer to use the Admin API
const { consumer, kafka } = require('./config/kafka');
const pool = require('./config/db');

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

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function runConsumer() {
  const topicName = 'crypto-orders';

  // config/kafka.js's `retry` options only cover low-level broker
  // *connection* retries (ECONNREFUSED while Kafka is still starting up).
  // They don't cover a failure in the setup sequence below — confirmed
  // live: on a fresh cluster, wallet-service's pod can win the race against
  // Kafka's own broker coming up. ensureTopicExists() then can't reach the
  // admin API either, silently gives up (see its own catch below), and the
  // topic isn't there yet when subscribe()/run() ask for its metadata a
  // moment later:
  //   KafkaJSProtocolError: This server does not host this topic-partition
  //   (UNKNOWN_TOPIC_OR_PARTITION)
  // That error used to propagate out of runConsumer() entirely — logged
  // once, then nothing: no more connect/subscribe attempts for the rest of
  // the pod's life, silently leaving `wallets` never updated (the "Wallet
  // Balances" feature returns 200 with an empty array for every user,
  // which looks fine at the HTTP layer while being completely broken).
  // Retrying the whole setup sequence, not just the low-level connection,
  // is what actually makes that self-healing.
  // Visibility into KafkaJS's own internal restart loop (it retries a
  // crashed consumer on its own — see the `retry` options in
  // config/kafka.js — this just makes that non-fatal churn observable
  // instead of only showing up as raw error logs). Registered once, outside
  // the retry loop below, so a setup retry doesn't stack duplicate listeners.
  consumer.on(consumer.events.CRASH, ({ payload }) => {
    console.error(`⚠️ [Consumer] Crash (recovering): ${payload.error.message}`, {
      restarting: payload.restart
    });
  });

  let attempt = 0;
  while (true) {
    attempt += 1;
    try {
      // Verify and create the topic dynamically before the consumer connects
      await ensureTopicExists(topicName);

      console.log('🔌 Connecting Kafka Consumer...');
      await consumer.connect();
      console.log('✅ Kafka Consumer connected successfully!');

      await consumer.subscribe({ topic: topicName, fromBeginning: true });
      console.log(`👂 Subscribed to topic: ${topicName}`);

      await consumer.run({
        eachMessage: async ({ topic, partition, message }) => {
          const rawValue = message.value.toString();
          console.log(`📥 [Received Event] Topic: ${topic} | Partition: ${partition}`);

          try {
            let payload = JSON.parse(rawValue);

            if (typeof payload === 'string') {
              payload = JSON.parse(payload);
            }

            const { userId, coin, amount, action } = payload;

            // 1. Basic validation on required payload properties
            if (!userId || !coin || !amount || !action) {
              console.warn('⚠️ [Malformed Message] Detailed check:', {
                payload,
                extracted: { userId, coin, amount, action },
                types: {
                  userId: typeof userId,
                  coin: typeof coin,
                  amount: typeof amount,
                  action: typeof action
                }
              });
              return;
            }

            const amountNum = parseFloat(amount);
            // 2. Determine modification: positive for "buy", negative for "sell"
            const balanceChange = action.toLowerCase() === 'buy' ? amountNum : -amountNum;

            console.log(`🔄 Processing: User ${userId} is trying to ${action} ${amount} ${coin}...`);

            // 3. SQL query to update the user's wallet using the UPSERT logic
            const updateQuery = `
              INSERT INTO wallets (user_id, currency, balance, updated_at)
              VALUES ($2, $3, $1, CURRENT_TIMESTAMP)
              ON CONFLICT (user_id, currency)
              DO UPDATE SET balance = wallets.balance + $1, updated_at = CURRENT_TIMESTAMP;
            `;

            // Using pool.query automatically acquires and releases a client connection back to the pool (no leaks)
            const result = await pool.query(updateQuery, [balanceChange, userId, coin.toUpperCase()]);

            console.log(`✅ Database synchronized! Balance adjusted by ${balanceChange} for ${userId} (${coin})`);

          } catch (parseError) {
            console.error('❌ Failed to parse or process message:', parseError.message);
          }
        },
      });

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