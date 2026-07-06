"""Thin wrapper around the Azure Storage Queue SDK, pointed at Azurite (the
official local Azure Storage emulator) instead of real Azure Storage. This
is the ONLY place that knows about Azurite - everything else in the demo
just calls queue-bridge over plain HTTP, so swapping Azurite for a real
Azure Storage account later is a one-line connection-string change here,
nothing else in the platform has to change.
"""
import os
from functools import lru_cache

from azure.storage.queue import QueueClient

# Azurite's fixed, publicly documented development account + key - safe to
# hardcode, it only ever exists on your laptop.
AZURITE_DEFAULT_CONNECTION_STRING = (
    "DefaultEndpointsProtocol=http;"
    "AccountName=devstoreaccount1;"
    "AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;"
    "QueueEndpoint=http://azurite.platform-azure.svc.cluster.local:10001/devstoreaccount1;"
)

QUEUE_NAME = os.environ.get("NOTIFICATIONS_QUEUE_NAME", "order-notifications")


@lru_cache(maxsize=1)
def get_queue_client() -> QueueClient:
    conn_str = os.environ.get("AZURE_STORAGE_CONNECTION_STRING", AZURITE_DEFAULT_CONNECTION_STRING)
    client = QueueClient.from_connection_string(conn_str, QUEUE_NAME)
    try:
        client.create_queue()
    except Exception:
        pass  # already exists - fine
    return client
