const { Kafka } = require('kafkajs');

const kafkaBroker = process.env.KAFKA_BROKERS || 'localhost:9092';

const kafka = new Kafka({
  clientId: 'wallet-service',
  brokers: [kafkaBroker]
});

const consumer = kafka.consumer({ groupId: 'wallet-group' });

module.exports = { kafka, consumer };