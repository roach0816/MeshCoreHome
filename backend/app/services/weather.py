"""Local weather from an Ecowitt gateway or Wi-Fi console (e.g. a WS90 via a GW1100/GW2000/GW3000).

Reads the gateway's local live-data endpoint, ``http://<gateway>/get_livedata_info``, which needs no
account or cloud connection (Ecowitt "HTTP API interface protocol", v1.0.5). Field IDs used here:

  common_list  0x02 outdoor temperature (with "unit"), 0x07 outdoor humidity ("65%"),
               0x0A wind direction (degrees), 0x0B wind speed, 0x0C gust ("1.12mph")
  piezoRain    the WS90's piezo rain gauge; rain is the same for tipping-bucket gauges
               0x7C rain in the last 24 hours (newer firmware), 0x10 rain today
  ch_pm25      PM2.5 sensors (WH41/WH43): PM25, PM25_RealAQI, PM25_24HAQI per channel
  co2          CO2 + particulate combo sensors (WH45/WH46): PM25, PM10, CO2, AQIs

Values arrive as text in the units chosen on the gateway ("79.2" + unit "F", "3.4mph", "0.12in"),
and are passed through in those units. Readings are cached briefly: the bot may be asked often.
"""

from __future__ import annotations

import re
import time
from typing import Any

import httpx

TIMEOUT = 6.0
CACHE_SECONDS = 60.0
DM_MAX_BYTES = 150
COMPASS = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
_NUM_UNIT = re.compile(r"^\s*(-?\d+(?:\.\d+)?)\s*([^\d\s].*)?$")

_cache: dict[str, tuple[float, dict[str, Any]]] = {}


class WeatherError(Exception):
    """The weather station could not be read; the message is safe to show."""


def _split(val: Any) -> tuple[float, str] | None:
    """ "3.40mph" → (3.4, "mph"); "68%" → (68.0, "%"); "--" or "" → None."""
    m = _NUM_UNIT.match(str(val or ""))
    if not m:
        return None
    return float(m.group(1)), (m.group(2) or "").strip()


def _num(x: float) -> str:
    """Compact number: 3.40 → "3.4", 68.0 → "68"."""
    return f"{x:.2f}".rstrip("0").rstrip(".")


def compass(degrees: float) -> str:
    return COMPASS[int((degrees % 360) / 22.5 + 0.5) % 16]


def _ids(items: Any) -> dict[str, dict[str, Any]]:
    return {str(i.get("id", "")).upper(): i for i in items or [] if isinstance(i, dict)}


def parse(data: dict[str, Any]) -> dict[str, Any]:
    """Pick the outdoor readings out of a get_livedata_info answer. Missing ones are left out."""
    if not isinstance(data, dict):
        raise WeatherError("The weather station sent an unexpected answer.")
    out: dict[str, Any] = {}
    common = _ids(data.get("common_list"))

    t = common.get("0X02")
    if t and (v := _split(t.get("val"))):
        unit = str(t.get("unit") or v[1] or "").upper().lstrip("°")
        out["temp"] = {"value": v[0], "unit": f"°{unit}" if unit in ("C", "F") else unit}
    if (h := common.get("0X07")) and (v := _split(h.get("val"))):
        out["humidity"] = v[0]
    for key, item_id in (("wind", "0X0B"), ("gust", "0X0C")):
        if (w := common.get(item_id)) and (v := _split(w.get("val"))):
            out[key] = {"value": v[0], "unit": v[1]}
    if (d := common.get("0X0A")) and (v := _split(d.get("val"))):
        out["wind_dir"] = v[0]

    # The WS90 reports a piezo gauge; fall back to a tipping-bucket gauge.
    for gauge in ("piezoRain", "rain"):
        rain = _ids(data.get(gauge))
        if not rain:
            continue
        if (r := rain.get("0X7C")) and (v := _split(r.get("val"))):
            out["rain"] = {"value": v[0], "unit": v[1], "period": "24h"}
        elif (r := rain.get("0X10")) and (v := _split(r.get("val"))):
            out["rain"] = {"value": v[0], "unit": v[1], "period": "today"}
        if "rain" in out:
            break

    aq: dict[str, Any] = {}
    pm = [c for c in data.get("ch_pm25") or [] if isinstance(c, dict)]
    if pm and (v := _split(pm[0].get("PM25"))):
        aq["pm25"] = v[0]
        if (a := _split(pm[0].get("PM25_RealAQI"))) is not None:
            aq["aqi"] = a[0]
    combo = next((c for c in data.get("co2") or [] if isinstance(c, dict)), None)
    if combo:
        if "pm25" not in aq and (v := _split(combo.get("PM25"))):
            aq["pm25"] = v[0]
            if (a := _split(combo.get("PM25_RealAQI"))) is not None:
                aq["aqi"] = a[0]
        if (v := _split(combo.get("PM10"))) is not None:
            aq["pm10"] = v[0]
        if (v := _split(combo.get("CO2"))) is not None:
            aq["co2"] = v[0]
    if aq:
        out["air"] = aq
    if not out:
        raise WeatherError("The weather station reported no outdoor readings.")
    return out


def format_reply(r: dict[str, Any], limit: int = DM_MAX_BYTES) -> str:
    """One DM: the most useful readings first; less important ones are dropped to fit."""
    parts: list[str] = []
    head = []
    if "temp" in r:
        head.append(f"{_num(r['temp']['value'])}{r['temp']['unit']}")
    if "humidity" in r:
        head.append(f"{_num(r['humidity'])}% RH")
    if head:
        parts.append(" ".join(head))
    if "wind" in r:
        w = f"wind {_num(r['wind']['value'])} {r['wind']['unit']}".rstrip()
        if "wind_dir" in r:
            w += f" {compass(r['wind_dir'])}"
        if "gust" in r:
            w += f", gust {_num(r['gust']['value'])}"
        parts.append(w)
    if "rain" in r:
        rain = r["rain"]
        parts.append(f"rain {rain['period']} {_num(rain['value'])} {rain['unit']}".rstrip())
    air = r.get("air") or {}
    aq = []
    if "aqi" in air:
        aq.append(f"AQI {_num(air['aqi'])}")
    if "pm25" in air:
        aq.append(f"PM2.5 {_num(air['pm25'])}")
    if "pm10" in air:
        aq.append(f"PM10 {_num(air['pm10'])}")
    if "co2" in air:
        aq.append(f"CO2 {_num(air['co2'])}ppm")
    while aq:
        candidate = " · ".join([*parts, " ".join(aq)])
        if len(candidate.encode()) <= limit:
            return candidate
        aq.pop()  # drop CO2, then PM10, … until it fits
    text = " · ".join(parts)
    return text if len(text.encode()) <= limit else text.encode()[: limit - 3].decode(errors="ignore") + "..."


async def read(host: str, *, use_cache: bool = True) -> dict[str, Any]:
    """Fetch and parse the gateway's live data (cached for a minute)."""
    host = host.strip()
    if not host:
        raise WeatherError("No weather station is set up.")
    hit = _cache.get(host)
    if use_cache and hit and time.monotonic() - hit[0] < CACHE_SECONDS:
        return hit[1]
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            res = await client.get(f"http://{host}/get_livedata_info")
            res.raise_for_status()
            data = res.json()
    except httpx.TimeoutException:
        raise WeatherError(f"The weather station at {host} did not answer in time.") from None
    except httpx.HTTPStatusError as exc:
        raise WeatherError(
            f"The weather station at {host} answered with HTTP {exc.response.status_code}."
        ) from None
    except (httpx.HTTPError, ValueError):
        raise WeatherError(f"Could not read the weather station at {host}.") from None
    reading = parse(data)
    _cache[host] = (time.monotonic(), reading)
    return reading
