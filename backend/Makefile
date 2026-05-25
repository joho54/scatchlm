LOGS_DIR := logs

$(LOGS_DIR):
	mkdir -p $(LOGS_DIR)

.PHONY: serve
serve: $(LOGS_DIR)
	source venv/bin/activate && uvicorn app.main:app --reload --loop asyncio --host 0.0.0.0 --port 18000 2>&1 | tee $(LOGS_DIR)/uvicorn.log

.PHONY: db-up
db-up:
	docker compose up -d

.PHONY: db-down
db-down:
	docker compose down

.PHONY: migrate
migrate:
	source venv/bin/activate && alembic upgrade head

.PHONY: test
test:
	source venv/bin/activate && pytest
