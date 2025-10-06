import os
import pika
import json
import time
import logging
from app.orders import create_order

# Configuration du logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

RABBITMQ_USER = os.getenv('RABBITMQ_USER')
RABBITMQ_PASSWORD = os.getenv('RABBITMQ_PASSWORD')
RABBITMQ_HOST = os.getenv('RABBITMQ_HOST')
RABBITMQ_PORT = int(os.getenv('RABBITMQ_PORT', 5672))  # Conversion en entier avec valeur par défaut
RABBITMQ_QUEUE = os.getenv('RABBITMQ_QUEUE')

def connect_to_rabbitmq(max_retries=10, retry_delay=5):
    """Établit une connexion robuste à RabbitMQ avec retry logic"""
    for attempt in range(max_retries):
        try:
            logger.info(f"Tentative de connexion à RabbitMQ ({attempt + 1}/{max_retries})")
            credentials = pika.PlainCredentials(RABBITMQ_USER, RABBITMQ_PASSWORD)
            connection = pika.BlockingConnection(
                pika.ConnectionParameters(
                    host=RABBITMQ_HOST,
                    port=RABBITMQ_PORT,
                    virtual_host='/',
                    credentials=credentials,
                    heartbeat=600,  # Heartbeat pour maintenir la connexion
                    blocked_connection_timeout=300,
                )
            )
            channel = connection.channel()
            channel.queue_declare(queue=RABBITMQ_QUEUE, durable=True)
            logger.info("Connexion à RabbitMQ établie avec succès")
            return connection, channel
            
        except pika.exceptions.AMQPConnectionError as e:
            if attempt < max_retries - 1:
                logger.warning(f"Échec de connexion à RabbitMQ: {e}")
                logger.info(f"Nouvelle tentative dans {retry_delay} secondes...")
                time.sleep(retry_delay)
            else:
                logger.error(f"Impossible de se connecter à RabbitMQ après {max_retries} tentatives")
                raise
        except Exception as e:
            logger.error(f"Erreur inattendue lors de la connexion: {e}")
            if attempt < max_retries - 1:
                time.sleep(retry_delay)
            else:
                raise

def consume_and_store_order(engine):
    """Consomme les messages de la queue et les traite"""
    connection = None
    channel = None
    
    try:
        # Établir la connexion avec retry logic
        connection, channel = connect_to_rabbitmq()
        
        def callback(
                ch: pika.channel.Channel,
                method: pika.spec.Basic.Deliver,
                properties: pika.spec.BasicProperties,
                body: bytes
        ):
            logger.info(f"Message reçu: {body.decode()}")
            try:
                new_order = json.loads(body.decode())
                create_order(engine, new_order)
                logger.info("Nouvelle commande créée avec succès")
                ch.basic_ack(delivery_tag=method.delivery_tag)
            except json.JSONDecodeError as e:
                logger.error(f"Erreur de décodage JSON: {e}")
                ch.basic_nack(delivery_tag=method.delivery_tag, requeue=False)
            except Exception as e:
                logger.error(f"Erreur lors du traitement de la commande: {e}")
                ch.basic_nack(delivery_tag=method.delivery_tag, requeue=True)

        channel.basic_qos(prefetch_count=1)  # Traiter un message à la fois
        channel.basic_consume(
            queue=RABBITMQ_QUEUE,
            on_message_callback=callback
        )
        
        logger.info("En attente de messages. Pour arrêter, appuyez sur CTRL+C")
        channel.start_consuming()
        
    except KeyboardInterrupt:
        logger.info("Arrêt demandé par l'utilisateur")
        if channel:
            channel.stop_consuming()
    except pika.exceptions.ConnectionClosedByBroker as e:
        logger.error(f"Connexion fermée par le broker: {e}")
        # Relancer la fonction pour reconnecter
        time.sleep(5)
        consume_and_store_order(engine)
    except Exception as e:
        logger.error(f"Erreur critique: {e}")
        raise
    finally:
        if connection and not connection.is_closed:
            connection.close()
            logger.info("Connexion fermée")