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

async function runConsumer() {
  try {
    const topicName = 'crypto-orders';

    // 2. Verify and create the topic dynamically before the consumer connects
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
  } catch (error) {
    console.error('❌ Critical Error running Kafka consumer:', error);
  }
}

module.exports = { runConsumer };