#!/usr/bin/env python3
import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_DASHBOARD_FILE = SCRIPT_DIR / "dashboards" / "nash-dataops-demo.json"


def load_env(path):
    if not path.exists():
        return

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not key or not key.replace("_", "").isalnum():
            continue
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        os.environ.setdefault(key, value)


class MetabaseClient:
    def __init__(self, base_url):
        self.base_url = base_url.rstrip("/")
        self.session_id = None

    def request(self, method, path, payload=None, query=None):
        url = f"{self.base_url}{path}"
        if query:
            url = f"{url}?{urllib.parse.urlencode(query, doseq=True)}"

        data = None
        headers = {"Accept": "application/json"}
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        if self.session_id:
            headers["X-Metabase-Session"] = self.session_id

        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                body = response.read().decode("utf-8")
                if not body:
                    return None
                return json.loads(body)
        except urllib.error.HTTPError as error:
            body = error.read().decode("utf-8")
            raise RuntimeError(f"{method} {path} failed with HTTP {error.code}: {body}") from error

    def login(self, email, password):
        response = self.request(
            "POST",
            "/api/session",
            {"username": email, "password": password},
        )
        self.session_id = response["id"]

    def get(self, path, query=None):
        return self.request("GET", path, query=query)

    def post(self, path, payload):
        return self.request("POST", path, payload=payload)

    def put(self, path, payload):
        return self.request("PUT", path, payload=payload)


def require_env(name):
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"{name} is required. Set it in metabase/.env.")
    return value


def find_by_name(items, name):
    return next((item for item in items if item.get("name") == name), None)


def ensure_collection(client, spec):
    collections = client.get("/api/collection")
    existing = find_by_name(collections, spec["collection_name"])
    payload = {
        "name": spec["collection_name"],
        "description": spec.get("collection_description"),
    }
    if existing:
        collection_id = existing["id"]
        client.put(f"/api/collection/{collection_id}", payload)
        print(f"Updated collection: {spec['collection_name']} ({collection_id})")
        return collection_id

    created = client.post("/api/collection", payload)
    print(f"Created collection: {spec['collection_name']} ({created['id']})")
    return created["id"]


def find_database_id(client, database_name):
    databases = client.get("/api/database").get("data", [])
    database = find_by_name(databases, database_name)
    if not database:
        available = ", ".join(sorted(db["name"] for db in databases))
        raise SystemExit(
            f"Metabase database '{database_name}' was not found. "
            f"Run ./setup-redshift-database.sh first. Available databases: {available}"
        )
    return database["id"]


def render_query(query, schema):
    return query.replace("{{schema}}", schema)


def card_payload(card, database_id, collection_id, schema):
    return {
        "name": card["name"],
        "description": card.get("description"),
        "display": card.get("display", "table"),
        "visualization_settings": card.get("visualization_settings", {}),
        "collection_id": collection_id,
        "type": "question",
        "dataset_query": {
            "database": database_id,
            "type": "native",
            "native": {
                "query": render_query(card["query"], schema),
                "template-tags": {},
            },
        },
        "parameters": [],
        "parameter_mappings": [],
    }


def is_question_card(card):
    return card.get("type", "question") == "question"


def is_virtual_card(card):
    return card.get("type") in {"heading", "text"}


def collection_cards(client, collection_id):
    return [
        card
        for card in client.get("/api/card")
        if card.get("collection_id") == collection_id and not card.get("archived")
    ]


def ensure_card(client, card, database_id, collection_id, schema, existing_cards):
    existing = find_by_name(existing_cards, card["name"])
    payload = card_payload(card, database_id, collection_id, schema)
    if existing:
        updated = client.put(f"/api/card/{existing['id']}", payload)
        print(f"Updated question: {card['name']} ({updated['id']})")
        return updated["id"]

    created = client.post("/api/card", payload)
    print(f"Created question: {card['name']} ({created['id']})")
    existing_cards.append(created)
    return created["id"]


def all_dashboards(client):
    return client.get("/api/dashboard", query={"f": "all"})


def ensure_dashboard(client, dashboard, collection_id):
    existing = next(
        (
            item
            for item in all_dashboards(client)
            if item.get("name") == dashboard["name"] and item.get("collection_id") == collection_id
        ),
        None,
    )
    payload = {
        "name": dashboard["name"],
        "description": dashboard.get("description"),
        "collection_id": collection_id,
        "parameters": [],
    }
    if existing:
        dashboard_id = existing["id"]
        client.put(f"/api/dashboard/{dashboard_id}", payload)
        print(f"Updated dashboard shell: {dashboard['name']} ({dashboard_id})")
        return dashboard_id

    created = client.post("/api/dashboard", payload)
    print(f"Created dashboard shell: {dashboard['name']} ({created['id']})")
    return created["id"]


def update_dashboard_layout(client, dashboard_id, dashboard, card_ids_by_slug):
    current = client.get(f"/api/dashboard/{dashboard_id}")
    current_dashcards = current.get("dashcards") or []
    existing_dashcards_by_card_id = {
        dashcard.get("card_id"): dashcard
        for dashcard in current_dashcards
        if dashcard.get("card_id") is not None
    }

    dashcards = []
    virtual_index = 1000
    for index, card in enumerate(dashboard["cards"], start=1):
        layout = card["layout"]
        if is_virtual_card(card):
            virtual_index += 1
            dashcards.append(
                {
                    "id": -virtual_index,
                    "card_id": None,
                    "row": layout["row"],
                    "col": layout["col"],
                    "size_x": layout["size_x"],
                    "size_y": layout["size_y"],
                    "parameter_mappings": [],
                    "visualization_settings": {
                        "dashcard.background": False,
                        "text": card["text"],
                        "virtual_card": {
                            "archived": False,
                            "dataset_query": {},
                            "display": card["type"],
                            "name": None,
                            "visualization_settings": {},
                        },
                    },
                    "series": [],
                }
            )
            continue

        card_id = card_ids_by_slug[card["slug"]]
        existing = existing_dashcards_by_card_id.get(card_id)
        dashcards.append(
            {
                "id": existing["id"] if existing else -index,
                "card_id": card_id,
                "row": layout["row"],
                "col": layout["col"],
                "size_x": layout["size_x"],
                "size_y": layout["size_y"],
                "parameter_mappings": [],
                "visualization_settings": card.get("dashcard_visualization_settings", {}),
                "series": [],
            }
        )

    updated = client.put(
        f"/api/dashboard/{dashboard_id}",
        {
            "name": dashboard["name"],
            "description": dashboard.get("description"),
            "collection_id": current.get("collection_id"),
            "parameters": [],
            "dashcards": dashcards,
            "tabs": [],
        },
    )
    print(f"Updated dashboard layout: {dashboard['name']} ({updated['id']})")


def run_validation_query(client, card_id):
    response = client.post(f"/api/card/{card_id}/query", {})
    status = response.get("status")
    if status != "completed":
        raise RuntimeError(f"Validation query for card {card_id} returned status={status}: {response}")
    return response


def import_dashboards(args):
    load_env(SCRIPT_DIR / ".env")
    load_env(SCRIPT_DIR / ".env.example")

    base_url = os.environ.get("METABASE_URL") or f"http://localhost:{os.environ.get('METABASE_HOST_PORT', '3001')}"
    email = require_env("METABASE_ADMIN_EMAIL")
    password = require_env("METABASE_ADMIN_PASSWORD")
    database_name = os.environ.get("METABASE_DATABASE_NAME", "Nash DataOps Redshift Dev")
    schema = os.environ.get("REDSHIFT_SCHEMA", "nyc_taxi")

    spec = json.loads(args.definition.read_text(encoding="utf-8"))
    client = MetabaseClient(base_url)
    client.login(email, password)

    database_id = find_database_id(client, database_name)
    collection_id = ensure_collection(client, spec)

    dashboard_urls = []
    validation_card_id = None
    existing_cards = collection_cards(client, collection_id)

    for dashboard in spec["dashboards"]:
        card_ids_by_slug = {}
        for card in dashboard["cards"]:
            if not is_question_card(card):
                continue
            card_id = ensure_card(client, card, database_id, collection_id, schema, existing_cards)
            card_ids_by_slug[card["slug"]] = card_id
            validation_card_id = validation_card_id or card_id

        dashboard_id = ensure_dashboard(client, dashboard, collection_id)
        update_dashboard_layout(client, dashboard_id, dashboard, card_ids_by_slug)
        dashboard_urls.append(f"{base_url}/dashboard/{dashboard_id}")

    if args.validate_query and validation_card_id is not None:
        result = run_validation_query(client, validation_card_id)
        rows = result.get("data", {}).get("rows", [])
        print(f"Validation query succeeded for card {validation_card_id}: {rows[:1]}")

    print("\nDashboards ready:")
    for url in dashboard_urls:
        print(f"- {url}")


def parse_args():
    parser = argparse.ArgumentParser(description="Import Nash DataOps demo dashboards into local Metabase.")
    parser.add_argument(
        "--definition",
        type=Path,
        default=DEFAULT_DASHBOARD_FILE,
        help=f"Dashboard definition JSON. Default: {DEFAULT_DASHBOARD_FILE}",
    )
    parser.add_argument(
        "--no-query-validation",
        action="store_false",
        dest="validate_query",
        help="Skip the final Metabase card query validation.",
    )
    parser.set_defaults(validate_query=True)
    return parser.parse_args()


if __name__ == "__main__":
    try:
        import_dashboards(parse_args())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
