import os
import logging
from urllib.parse import urljoin, urlencode

import requests
from flask import Blueprint, request, Response, jsonify

log = logging.getLogger(__name__)
log.setLevel(logging.INFO)

INVENTORY_APP_HOST = os.getenv("INVENTORY_APP_HOST", "inventory-app.microservices.svc.cluster.local")
INVENTORY_APP_PORT = os.getenv("INVENTORY_APP_PORT", "8080")

# (optionnel) support billing si tu veux l’étendre plus tard
BILLING_APP_HOST = os.getenv("BILLING_APP_HOST", "billing-app-0.billing-app.microservices.svc.cluster.local")
BILLING_APP_PORT = os.getenv("BILLING_APP_PORT", "8080")

bp = Blueprint("proxy", __name__)

@bp.route('/', methods=["GET"])
def root():
    return jsonify({"ok": True, "hint": "use /api/movies"}), 200

@bp.route('/<path:path>', methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
def gateway(path: str):
    """
    /api/<service>/<...>  --> forward vers service mappé
      ex: /api/movies        -> inventory-app
    """
    service_mapping = {
        "movies": f"http://{INVENTORY_APP_HOST}:{INVENTORY_APP_PORT}",
        # "billing": f"http://{BILLING_APP_HOST}:{BILLING_APP_PORT}",  # si besoin
    }

    # ex: "movies" ou "movies/123"
    segments = [p for p in path.split('/') if p]
    if not segments:
        return jsonify({"error": "empty path"}), 404

    # Supporte les chemins avec préfixe /api/ (ex: /api/movies)
    if segments and segments[0].lower() == "api":
        segments = segments[1:]
    if not segments:
        return jsonify({"error": "empty path"}), 404

    service_name = segments[0]
    base_url = service_mapping.get(service_name)
    if not base_url:
        return jsonify({"error": f"Unknown service '{service_name}'"}), 404

    # Normalise: supprime le slash final (sauf racine) pour éviter 404 en amont
    normalized_path = request.path
    if normalized_path != '/' and normalized_path.endswith('/'):
        normalized_path = normalized_path[:-1]

    # Conserve le chemin complet (incluant /api/...) et ajoute la query string
    target_url = urljoin(base_url, normalized_path)
    if request.query_string:
        target_url = f"{target_url}?{request.query_string.decode('utf-8')}"
    log.info("→ %s %s -> %s", request.method, path, target_url)

    # Prépare la requête vers l’upstream
    headers = {k: v for k, v in request.headers if k.lower() != "host"}
    data = request.get_data() if request.data else None

    try:
        upstream = requests.request(
            method=request.method,
            url=target_url,
            headers=headers,
            data=data,
            timeout=10,
        )
    except requests.RequestException as e:
        log.exception("Upstream error to %s: %s", target_url, e)
        return jsonify({"error": "Upstream unavailable"}), 503

    # Réexpédie la réponse telle quelle
    resp = Response(upstream.content, status=upstream.status_code)
    # Copie les en-têtes utiles
    for k, v in upstream.headers.items():
        if k.lower() not in {"content-length", "transfer-encoding", "connection"}:
            resp.headers[k] = v
    return resp
