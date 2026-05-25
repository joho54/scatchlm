"""Unit tests — no DB required. Override parent conftest fixtures."""
import pytest


@pytest.fixture(scope="session")
async def engine():
    yield None


@pytest.fixture(autouse=True)
async def clean_tables(engine):
    yield
