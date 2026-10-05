"""Weather from an Ecowitt gateway (get_livedata_info), shaped like Ecowitt's documented examples."""

import time

import httpx
import pytest

from app.radio.base import IncomingMessage
from app.services import bot, weather
from tests.conftest import csrf, do_setup, radio_adapter, wait_for
from tests.test_api import _connected_conversations

REAL_CLIENT = httpx.AsyncClient  # kept: tests patch httpx.AsyncClient more than once

# A GW2000 with a WS90 and a WH41 PM2.5 sensor, units set to °F / mph / in.
IMPERIAL = {
    "common_list": [
        {"id": "0x02", "val": "79.2", "unit": "F"},
        {"id": "0x07", "val": "65%"},
        {"id": "3", "val": "79.2", "unit": "F"},
        {"id": "0x03", "val": "66.4", "unit": "F"},
        {"id": "0x0B", "val": "3.40mph"},
        {"id": "0x0C", "val": "6.04mph"},
        {"id": "0x19", "val": "11.41mph"},
        {"id": "0x15", "val": "512.00w/m2"},
        {"id": "0x17", "val": "4"},
        {"id": "0x0A", "val": "37", "battery": "5"},
    ],
    "piezoRain": [
        {"id": "0x0D", "val": "0.12in"},
        {"id": "0x0E", "val": "0.00in/Hr"},
        {"id": "0x7C", "val": "0.31in"},
        {"id": "0x10", "val": "0.12in"},
        {"id": "0x11", "val": "0.50in"},
        {"id": "0x13", "val": "20.37in", "battery": "4"},
    ],
    "wh25": [{"intemp": "71.0", "unit": "F", "inhumi": "40%", "abs": "29.40inHg", "rel": "29.40inHg"}],
    "ch_pm25": [{"channel": "1", "PM25": "11.0", "PM25_RealAQI": "46", "PM25_24HAQI": "55", "battery": "6"}],
}

# Older firmware (no 24-hour total), metric units, a WH46 combo sensor and no WH41.
METRIC_OLD = {
    "common_list": [
        {"id": "0x02", "val": "21.5", "unit": "C"},
        {"id": "0x07", "val": "58%"},
        {"id": "0x0B", "val": "1.5m/s"},
        {"id": "0x0C", "val": "3.1m/s"},
        {"id": "0x0A", "val": "250"},
    ],
    "piezoRain": [{"id": "0x0D", "val": "0.0 mm"}, {"id": "0x10", "val": "2.4 mm"}],
    "co2": [
        {"temp": "24.0", "unit": "C", "PM25": "13.0", "PM25_RealAQI": "53", "PM10": "13.9", "CO2": "880"}
    ],
}


def test_parse_and_format_imperial():
    r = weather.parse(IMPERIAL)
    assert r["temp"] == {"value": 79.2, "unit": "°F"} and r["humidity"] == 65
    assert r["wind"] == {"value": 3.4, "unit": "mph"} and r["wind_dir"] == 37
    assert r["rain"] == {"value": 0.31, "unit": "in", "period": "24h"}
    assert r["air"] == {"pm25": 11.0, "aqi": 46}
    text = weather.format_reply(r)
    assert text == "79.2°F 65% RH · wind 3.4 mph NE, gust 6.04 · rain 24h 0.31 in · AQI 46 PM2.5 11"
    assert len(text.encode()) <= 150


def test_parse_older_firmware_metric_combo_sensor():
    r = weather.parse(METRIC_OLD)
    assert r["rain"] == {"value": 2.4, "unit": "mm", "period": "today"}
    assert r["air"] == {"pm25": 13.0, "aqi": 53, "pm10": 13.9, "co2": 880}
    text = weather.format_reply(r)
    assert (
        text
        == "21.5°C 58% RH · wind 1.5 m/s WSW, gust 3.1 · rain today 2.4 mm · AQI 53 PM2.5 13 PM10 13.9 CO2 880ppm"
    )


def test_format_drops_least_important_to_fit():
    r = weather.parse(METRIC_OLD)
    short = weather.format_reply(r, limit=90)
    assert len(short.encode()) <= 90 and "CO2" not in short and short.startswith("21.5°C")


def test_compass_and_bad_answers():
    assert [weather.compass(d) for d in (0, 11, 12, 90, 180, 349, 359)] == [
        "N",
        "N",
        "NNE",
        "E",
        "S",
        "N",
        "N",
    ]
    with pytest.raises(weather.WeatherError):
        weather.parse({"common_list": [{"id": "0x02", "val": "--"}]})
    with pytest.raises(weather.WeatherError):
        weather.parse(["not", "a", "dict"])


def _mock_station(monkeypatch, payload=None, status_code=200):
    seen = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(str(request.url))
        if payload is None:
            raise httpx.ConnectError("unreachable", request=request)
        return httpx.Response(status_code, json=payload)

    monkeypatch.setattr(
        weather.httpx, "AsyncClient", lambda **kw: REAL_CLIENT(transport=httpx.MockTransport(handler), **kw)
    )
    weather._cache.clear()
    return seen


async def test_settings_test_endpoint(client, monkeypatch):
    await do_setup(client)
    seen = _mock_station(monkeypatch, IMPERIAL)
    r = await client.post("/api/settings/weather/test", headers=csrf(client), json={"host": "station.test"})
    assert r.status_code == 200, r.text
    assert seen == ["http://station.test/get_livedata_info"]
    assert r.json()["reply"].startswith("79.2°F")

    r = await client.put(
        "/api/settings/weather", headers=csrf(client), json={"host": "http://station.test/x"}
    )
    assert r.status_code == 422
    r = await client.put("/api/settings/weather", headers=csrf(client), json={"host": " station.test:8080 "})
    assert r.status_code == 200 and r.json() == {"host": "station.test:8080"}
    assert (await client.get("/api/settings/weather")).json() == {"host": "station.test:8080"}

    _mock_station(monkeypatch, None)
    r = await client.post("/api/settings/weather/test", headers=csrf(client), json={"host": "station.test"})
    assert r.status_code == 502 and "station.test" in r.json()["detail"]


async def test_bot_weather_command(client, monkeypatch):
    from app.radio import simulated

    simulated._SIM_STATE = None
    bot._last_reply.clear()
    bot._recent.clear()
    await do_setup(client)
    await _connected_conversations(client)
    await client.put("/api/settings/bot", headers=csrf(client), json={"enabled": True, "allow": "everyone"})

    async def bot_replies() -> list[str]:
        convs = (await client.get("/api/conversations")).json()
        conv = next((c for c in convs if c["title"].startswith("Tracker")), None)
        if conv is None:
            return []
        msgs = (await client.get(f"/api/conversations/{conv['id']}/messages?limit=200")).json()["messages"]
        return [m["body"] for m in msgs if m["direction"] == "out" and m["meta"].get("bot")]

    async def ask(text: str) -> str:
        bot._last_reply.clear()
        before = len(await bot_replies())
        (await radio_adapter()).inject(
            IncomingMessage(
                kind="dm",
                text=text,
                pubkey_prefix=simulated._key("tracker")[:12],
                sender_timestamp=int(time.time()),
            )
        )

        async def new_reply():
            replies = await bot_replies()
            return replies[-1] if len(replies) > before else None

        return await wait_for(new_reply)

    assert await ask("/weather") == "No weather station is set up on this node."
    assert "/weather" not in await ask("/help")

    await client.put("/api/settings/weather", headers=csrf(client), json={"host": "station.test"})
    _mock_station(monkeypatch, IMPERIAL)
    # (Each command differs: identical messages within a second are treated as one, like radio repeats.)
    assert (await ask("/weather please")).startswith("79.2°F 65% RH · wind 3.4 mph NE")
    assert "/weather (local weather)" in await ask("/help again")

    _mock_station(monkeypatch, None)
    failed = await ask("/Weather")
    assert failed == "The weather station is not answering right now."  # no network address on air
