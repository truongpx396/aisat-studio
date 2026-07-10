"""Pytest fixtures providing Testcontainers-backed infrastructure for integration tests."""

from __future__ import annotations

import pytest

pytestmark = pytest.mark.integration

try:
    from testcontainers.core.container import DockerContainer
    from testcontainers.postgres import PostgresContainer
    from testcontainers.redis import RedisContainer

    _TESTCONTAINERS_AVAILABLE = True
except ImportError:
    _TESTCONTAINERS_AVAILABLE = False


def _require_testcontainers() -> None:
    if not _TESTCONTAINERS_AVAILABLE:
        pytest.skip("testcontainers not installed; skipping infrastructure fixture")


@pytest.fixture(scope="session")
def postgres_url() -> str:  # type: ignore[return]
    """Start a PostgreSQL 16 container and yield an asyncpg-compatible DSN."""
    _require_testcontainers()
    with PostgresContainer(
        image="postgres:16-alpine",
        username="test",
        password="test",
        dbname="testdb",
    ) as pg:
        host = pg.get_container_host_ip()
        port = pg.get_exposed_port(5432)
        yield f"postgresql+asyncpg://test:test@{host}:{port}/testdb"


@pytest.fixture(scope="session")
def redis_url() -> str:  # type: ignore[return]
    """Start a Redis 7 container and yield a redis:// URL."""
    _require_testcontainers()
    with RedisContainer(image="redis:7-alpine") as redis:
        host = redis.get_container_host_ip()
        port = redis.get_exposed_port(6379)
        yield f"redis://{host}:{port}"


@pytest.fixture(scope="session")
def nats_url() -> str:  # type: ignore[return]
    """Start a NATS 2.10 container with JetStream enabled and yield a nats:// URL."""
    _require_testcontainers()
    with (
        DockerContainer(image="nats:2.10-alpine")
        .with_command("-js")
        .with_exposed_ports(4222) as nats
    ):
        host = nats.get_container_host_ip()
        port = nats.get_exposed_port(4222)
        yield f"nats://{host}:{port}"


@pytest.fixture(scope="session")
def qdrant_url() -> str:  # type: ignore[return]
    """Start a Qdrant v1.12.0 container and yield an http:// URL (HTTP port 6333)."""
    _require_testcontainers()
    with (
        DockerContainer(image="qdrant/qdrant:v1.12.0").with_exposed_ports(6333) as qdrant
    ):
        host = qdrant.get_container_host_ip()
        port = qdrant.get_exposed_port(6333)
        yield f"http://{host}:{port}"
