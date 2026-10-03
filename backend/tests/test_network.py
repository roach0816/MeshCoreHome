import json
import time

import pytest

from app.config import get_settings
from tests.conftest import csrf, do_setup


@pytest.fixture
def native(monkeypatch, tmp_path):
    s = get_settings()
    monkeypatch.setattr(s, "install_kind", "native")
    monkeypatch.setattr(s, "state_dir", str(tmp_path))
    return tmp_path


def snapshot(d, **over):
    data = {
        "app_port": 8080,
        "bind": "0.0.0.0",
        "https_enabled": False,
        "hostname": None,
        "https_port": 443,
        "redirect_http": True,
        "email": None,
        "staging": False,
        "dns_provider": "cloudflare",
        "propagation_seconds": 30,
        "token_saved": False,
        "https_packages_installed": False,
        "auto_renew": False,
        "updated_at": time.time(),
    }
    data.update(over)
    (d / "network.json").write_text(json.dumps(data))


GOOD = {
    "app_port": 8080,
    "https_enabled": True,
    "hostname": "Meshcore.Example.com",
    "https_port": 443,
    "redirect_http": True,
    "email": "me@example.com",
    "staging": False,
    "propagation_seconds": 30,
    "cf_token": "abcdefghijklmnopqrstuvwxyz0123456789ABCD",
}


async def test_container_install_is_read_only(client):
    await do_setup(client, mode="none")
    info = (await client.get("/api/system/network")).json()
    assert info["configurable"] is False and info["config"] is None
    r = await client.put("/api/system/network", headers=csrf(client), json=GOOD)
    assert r.status_code == 409


async def test_missing_snapshot_triggers_refresh(client, native):
    await do_setup(client, mode="none")
    info = (await client.get("/api/system/network")).json()
    assert info["configurable"] is True and info["config"] is None
    assert json.loads((native / "config-request.json").read_text())["action"] == "refresh"


async def test_apply_writes_private_request_without_storing_token(client, native):
    await do_setup(client, mode="none")
    snapshot(native)
    r = await client.put("/api/system/network", headers=csrf(client), json=GOOD)
    assert r.status_code == 202
    req_file = native / "config-request.json"
    req = json.loads(req_file.read_text())
    assert oct(req_file.stat().st_mode & 0o777) == "0o600"
    assert (
        req["action"] == "apply"
        and req["hostname"] == "meshcore.example.com"
        and req["cf_token"] == GOOD["cf_token"]
    )
    # One change at a time while the request is pending.
    again = await client.put("/api/system/network", headers=csrf(client), json=GOOD)
    assert again.status_code == 409
    # The token never comes back from the API.
    assert GOOD["cf_token"] not in (await client.get("/api/system/network")).text


@pytest.mark.parametrize(
    "change, detail",
    [
        ({"app_port": 80}, None),  # unprivileged app cannot bind < 1024
        ({"hostname": "not a host"}, "hostname"),
        ({"https_port": 8080}, "must differ"),
        ({"email": "nope"}, None),
        ({"cf_token": "short"}, None),
        ({"propagation_seconds": 5}, None),
    ],
)
async def test_validation(client, native, change, detail):
    await do_setup(client, mode="none")
    snapshot(native)
    r = await client.put("/api/system/network", headers=csrf(client), json={**GOOD, **change})
    assert r.status_code == 422
    if detail:
        assert detail in r.text
    assert not (native / "config-request.json").exists()


async def test_token_required_only_when_none_saved(client, native):
    await do_setup(client, mode="none")
    body = {**GOOD, "cf_token": None}
    snapshot(native, token_saved=False)
    assert (await client.put("/api/system/network", headers=csrf(client), json=body)).status_code == 422
    snapshot(native, token_saved=True)
    assert (await client.put("/api/system/network", headers=csrf(client), json=body)).status_code == 202
    assert json.loads((native / "config-request.json").read_text())["cf_token"] == ""


async def test_disable_https_needs_no_hostname_or_token(client, native):
    await do_setup(client, mode="none")
    snapshot(native, https_enabled=True, hostname="meshcore.example.com", token_saved=True)
    body = {"app_port": 8081, "https_enabled": False}
    assert (await client.put("/api/system/network", headers=csrf(client), json=body)).status_code == 202


async def test_renew_requires_https(client, native):
    await do_setup(client, mode="none")
    snapshot(native, https_enabled=False)
    assert (await client.post("/api/system/network/renew", headers=csrf(client))).status_code == 409
    snapshot(native, https_enabled=True, hostname="meshcore.example.com")
    assert (await client.post("/api/system/network/renew", headers=csrf(client))).status_code == 202
    assert json.loads((native / "config-request.json").read_text())["action"] == "renew"
