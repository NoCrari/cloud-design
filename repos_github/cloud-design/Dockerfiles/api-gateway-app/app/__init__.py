from flask import Flask, request, jsonify, Response

from app.queue_sender import send_message_to_billing_queue
from app.proxy import bp as bp_proxy
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST


# Prometheus metrics
REQUEST_COUNT = Counter(
    'http_requests_total', 'Total HTTP requests', ['method', 'endpoint', 'http_status']
)
REQUEST_LATENCY = Histogram(
    'http_request_duration_seconds', 'HTTP request latency (s)', ['method', 'endpoint']
)


def create_app():

    app = Flask(__name__)

    app.register_blueprint(bp_proxy)

    # Metrics endpoint
    @app.route('/metrics')
    def metrics():
        data = generate_latest()
        return Response(data, mimetype=CONTENT_TYPE_LATEST)

    @app.errorhandler(Exception)
    def unhandled_exception(error):
        response = jsonify({'error': f'{error}'})
        response.status_code = 500
        return response

    @app.errorhandler(404)
    def not_found_error(error):
        response = jsonify({'error': 'Not Found'})
        response.status_code = 404
        return response

    @app.before_request
    def start_timer():
        request._prom_start_timer = REQUEST_LATENCY.labels(
            request.method, request.path
        ).time()

    @app.after_request
    def record_metrics(response):
        try:
            if hasattr(request, '_prom_start_timer'):
                request._prom_start_timer()
            REQUEST_COUNT.labels(
                request.method, request.path, response.status_code
            ).inc()
        except Exception:
            pass
        return response

    @app.route("/api/billing/", methods=["POST"])
    def send_to_billing_queue():
        if not request.is_json:
            return jsonify(error="Body must be JSON"), 400

        body = request.get_json()
        send_message_to_billing_queue(body)
        return jsonify(message=f"{body} sent"), 200

    return app
