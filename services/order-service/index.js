const express = require('express');
const { Kafka } = require('kafkajs');

const app = express();
app.use(express.json());

const PORT = process.env.PORT || 3000;

const kafkaBrokers = process.env.KAFKA_BROKERS
  ? process.env.KAFKA_BROKERS.split(',')
  : ['kafka.kafka.svc.cluster.local:9092'];

const kafka = new Kafka({
  clientId: 'order-service',
  brokers: kafkaBrokers,
  retry: {
    initialRetryTime: 300,
    retries: 8,
    maxRetryTime: 30000
  }
});

const producer = kafka.producer();

// Connects in the background — a Kafka outage at boot must not block the
// HTTP server from coming up (that's what caused it to fail readiness in
// the first place). connectWithRetry keeps trying instead of giving up
// after one attempt; /orders itself still guards against a not-yet-connected
// producer via producer.send()'s own connect-on-demand behavior.
async function connectWithRetry(delayMs = 5000) {
  try {
    await producer.connect();
    console.log('Successfully connected to Kafka Producer.');
  } catch (error) {
    console.error(`Failed to connect to Kafka Producer, retrying in ${delayMs}ms:`, error.message);
    setTimeout(() => connectWithRetry(Math.min(delayMs * 2, 60000)), delayMs);
  }
}
connectWithRetry();

// A rejected promise anywhere in the Kafka client (or elsewhere) must be
// logged, not allowed to crash the process and take the HTTP server down
// with it.
process.on('unhandledRejection', (reason) => {
  console.error('Unhandled promise rejection:', reason);
});

app.post('/orders', async (req, res) => {
  // 1. Extract action along with the other required fields
  const { userId, coin, amount, action } = req.body;

  // 2. Validate that all fields exist and that action is either 'buy' or 'sell'
  if (!userId || !coin || !amount || !action) {
    return res.status(400).send({ error: 'Missing required fields: userId, coin, amount, or action' });
  }

  const normalizedAction = action.toLowerCase();
  if (normalizedAction !== 'buy' && normalizedAction !== 'sell') {
    return res.status(400).send({ error: 'Invalid action. Must be either "buy" or "sell"' });
  }

  try {
    // 3. Include the validated action in the event payload
    const orderEvent = {
      userId,
      coin,
      amount,
      action: normalizedAction,
      timestamp: new Date().toISOString()
    };

    await producer.send({
      topic: 'crypto-orders',
      messages: [
        { 
          key: userId.toString(),
          value: JSON.stringify(orderEvent) 
        }
      ],
    });

    console.log(`Order published to Kafka: ${JSON.stringify(orderEvent)}`);
    
    return res.status(202).send({ 
      message: 'Order received and is being processed asynchronously.', 
      order: orderEvent 
    });

  } catch (error) {
    console.error('Error publishing order to Kafka:', error);
    return res.status(500).send({ error: 'Internal server error processing order' });
  }
});

app.get('/health', (req, res) => {
  res.send({ status: 'UP' });
});

app.get('/', (req, res) => {
  res.status(200).json({
    service: 'order-service',
    status: 'operational',
    message: 'Order Service API is active'
  });
});

app.listen(PORT, () => {
  console.log(`Order Service listening on port ${PORT}`);
});