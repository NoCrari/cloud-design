from flask import Flask, Response, request
import os

from app.extensions import db
from app.movies import bp as bp_movies
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
import time
import threading
from sqlalchemy import text

DB_HOST = os.getenv("INVENTORY_DB_HOST", "inventory-db")
DB_PORT = os.getenv("INVENTORY_DB_PORT", "5432")
DB_USER = os.getenv("INVENTORY_DB_USER")
DB_PASS = os.getenv("INVENTORY_DB_PASSWORD")
DB_NAME = os.getenv("INVENTORY_DB_NAME")

DB_URI = (
    "postgresql://"
    f"{DB_USER}:{DB_PASS}@{DB_HOST}:{DB_PORT}/{DB_NAME}"
)


def create_app(test_config=None):
    app = Flask(__name__)
    app.config.from_mapping(
        SQLALCHEMY_DATABASE_URI=DB_URI
    )
    if test_config is not None:
        # load the test config if passed in
        app.config.from_mapping(test_config)

    app.register_blueprint(bp_movies)

    # Prometheus metrics
    REQUEST_COUNT = Counter(
        'inventory_http_requests_total', 'Total HTTP requests', ['method', 'endpoint', 'http_status']
    )
    REQUEST_LATENCY = Histogram(
        'inventory_http_request_duration_seconds', 'HTTP request latency (s)', ['method', 'endpoint']
    )

    @app.route('/metrics')
    def metrics():
        data = generate_latest()
        return Response(data, mimetype=CONTENT_TYPE_LATEST)

    @app.before_request
    def start_timer():
        # Only time known endpoints; ignore static/metrics to reduce noise
        if not (getattr(request, 'path', '') or '').startswith('/metrics'):
            app._prom_timer = REQUEST_LATENCY.labels(
                getattr(request, 'method', 'GET'), getattr(request, 'path', '/')
            ).time()

    @app.after_request
    def record_metrics(response):
        try:
            timer = getattr(app, '_prom_timer', None)
            if timer:
                timer()
            REQUEST_COUNT.labels(
                getattr(request, 'method', 'GET'), getattr(request, 'path', '/'), response.status_code
            ).inc()
        except Exception:
            pass
        return response
    db.init_app(app)

    # Initialize DB in a background thread so the server can start immediately
    def _init_db_async():
        with app.app_context():
            for attempt in range(90):  # ~3 minutes
                try:
                    db.session.execute(text("SELECT 1"))
                    db.create_all()
                    print("[inventory-app] DB ready and schema ensured")
                    return
                except Exception as e:
                    print(f"[inventory-app] DB not ready (attempt {attempt+1}): {e}")
                    time.sleep(2)
            print("[inventory-app] DB init timed out; app will keep running and retry on demand")

    threading.Thread(target=_init_db_async, daemon=True).start()

    return app
