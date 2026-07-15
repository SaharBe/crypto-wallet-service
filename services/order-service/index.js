const express = require('express');
const { Kafka } = require('kafkajs');

const app = express();
app.use(express.json());

const PORT = process.env.PORT || 3000;

const kafkaBrokers = process.env.KAFKA_BROKERS 
  ? process.env.KAFKA_BROKERS.split(',') 
  : ['kafka-controller-0.kafka-controller-headless.kafka.svc.cluster.local:9092'];

const kafka = new Kafka({
  clientId: 'order-service',
  brokers: kafkaBrokers
});

const producer = kafka.producer();

async function initKafka() {
  try {
    await producer.connect();
    console.log('Successfully connected to Kafka Producer.');
  } catch (error) {
    console.error('Failed to connect to Kafka Producer:', error);
  }
}
initKafka();

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

app.listen(PORT, () => {
  console.log(`Order Service listening on port ${PORT}`);
});