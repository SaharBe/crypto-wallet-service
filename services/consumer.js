const { consumer } = require('../config/kafka');
const pool = require('../config/db');

async function runConsumer() {
  try {
    console.log('🔌 Connecting Kafka Consumer...');
    await consumer.connect();
    console.log('✅ Kafka Consumer connected successfully!');

    await consumer.subscribe({ topic: 'crypto-orders', fromBeginning: true });
    console.log('👂 Subscribed to topic: crypto-orders');

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

          // 3. SQL query to update the user's wallet
          const updateQuery = `
            UPDATE wallets 
            SET balance = balance + $1, updated_at = CURRENT_TIMESTAMP
            WHERE user_id = $2 AND currency = $3;
          `;

          // Using pool.query automatically acquires and releases a client connection back to the pool (no leaks)
          const result = await pool.query(updateQuery, [balanceChange, userId, coin.toUpperCase()]);

          if (result.rowCount === 0) {
            console.warn(`⚠️ Wallet not found for User: ${userId} and Coin: ${coin}. (No DB rows updated)`);
          } else {
            console.log(`✅ Database updated! Balance adjusted by ${balanceChange} for ${userId} (${coin})`);
          }

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