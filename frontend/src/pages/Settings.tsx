import { useEffect, useState, type ReactNode } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "react-router";
import { ChevronLeft, Download, Pause, Play, PlugZap, SlidersHorizontal, Sparkles, Trash2, UserRound } from "lucide-react";
import { api, type Device, type MapConfig, type Me, type RadioConfig, type RadioMode } from "../lib/api";
import { Badge, Button, Card, ErrorText, Field, Input } from "../components/ui";
import { radioSummary } from "../components/StatusPill";
import { useStatus } from "./Shell";
import { applyTheme, cx, formatDateTime, getThemePref, relativeSeconds, type ThemePref } from "../lib/util";

function Section({ title, description, children }: { title: string; description?: ReactNode; children: ReactNode }) {
  return (
    <Card className="p-4 sm:p-5">
      <h3 className="text-base font-semibold">{title}</h3>
      {description && <p className="mt-0.5 text-sm text-muted">{description}</p>}
      <div className="mt-4 space-y-4">{children}</div>
    </Card>
  );
}

function Row({ k, children }: { k: string; children: ReactNode }) {
  return (
    <div className="flex justify-between gap-4 py-1.5 text-sm">
      <dt className="shrink-0 text-muted">{k}</dt>
      <dd className="min-w-0 break-words text-right">{children}</dd>
    </div>
  );
}

export function Settings({ me }: { me: Me }) {
  return (
    <div className="flex h-full flex-col">
      <header className="flex items-center gap-2 border-b border-line bg-surface px-1.5 py-1.5 md:px-4">
        <Link
          to="/"
          className="inline-flex size-11 items-center justify-center rounded-lg text-muted hover:bg-surface-2 md:hidden"
          aria-label="Back to conversations"
        >
          <ChevronLeft className="size-6" />
        </Link>
        <h2 className="flex-1 px-1 py-2 text-base font-semibold">Settings</h2>
      </header>
      <div className="min-h-0 flex-1 overflow-y-auto p-3 md:p-6">
        <div className="mx-auto max-w-3xl space-y-4">
          <RadioSection />
          <DeviceSection />
          <GapsSection />
          <MapSection />
          <AppearanceSection />
          <AccountSection me={me} />
          <DataSection />
        </div>
      </div>
    </div>
  );
}

function RadioSection() {
  const qc = useQueryClient();
  const status = useStatus();
  const cfg = useQuery({ queryKey: ["radio-settings"], queryFn: () => api<RadioConfig>("/api/settings/radio") });
  const [mode, setMode] = useState<RadioMode>("none");
  const [host, setHost] = useState("");
  const [port, setPort] = useState("5000");
  const [interval, setIntervalS] = useState("60");

  useEffect(() => {
    if (!cfg.data) return;
    setMode(cfg.data.mode);
    setHost(cfg.data.host);
    setPort(String(cfg.data.port));
    setIntervalS(String(cfg.data.sim_interval_seconds));
  }, [cfg.data]);

  const invalidate = () => {
    qc.invalidateQueries({ queryKey: ["radio-settings"] });
    qc.invalidateQueries({ queryKey: ["status"] });
  };
  const save = useMutation({
    mutationFn: () =>
      api<RadioConfig>("/api/settings/radio", {
        method: "PUT",
        json: { mode, host: host.trim(), port: Number(port), sim_interval_seconds: Number(interval) },
      }),
    onSuccess: invalidate,
  });
  const test = useMutation({
    mutationFn: () =>
      api<{ reachable: boolean; detail: string }>("/api/radio/test-connection", {
        json: { host: host.trim(), port: Number(port) },
      }),
  });
  const pause = useMutation({
    mutationFn: (p: boolean) => api(`/api/radio/${p ? "pause" : "resume"}`, { method: "POST" }),
    onSuccess: invalidate,
  });
  const simulate = useMutation({ mutationFn: () => api("/api/radio/simulate-incoming", { method: "POST" }) });

  const r = status.data?.radio;
  const summary = radioSummary(status.data);
  const dirty =
    cfg.data &&
    (mode !== cfg.data.mode ||
      host.trim() !== cfg.data.host ||
      Number(port) !== cfg.data.port ||
      Number(interval) !== cfg.data.sim_interval_seconds);

  return (
    <Section
      title="Radio connection"
      description="The server keeps one connection to your home radio and collects messages even when no browser is open."
    >
      <div className="rounded-lg border border-line bg-surface-2/50 p-3">
        <p className="flex items-center gap-2 text-sm font-medium">
          <Badge tone={summary.tone === "muted" ? "muted" : summary.tone}>{summary.label}</Badge>
        </p>
        {r && (
          <dl className="mt-2 divide-y divide-line">
            <Row k="Detail">{r.detail || "—"}</Row>
            <Row k="Last radio interaction">{relativeSeconds(r.last_interaction_at, status.data?.server_time)}</Row>
            <Row k="Received / sent (this run)">
              {r.received} / {r.sent}
            </Row>
            <Row k="Reconnect attempts">{r.reconnects}</Row>
            {r.next_retry_at && <Row k="Next retry">{relativeSeconds(r.next_retry_at, status.data?.server_time).replace(" ago", "")}</Row>}
            {r.last_error && <Row k="Last error">{r.last_error}</Row>}
            {r.storage_warning && <Row k="Storage">{r.storage_warning}</Row>}
            {status.data && !status.data.app.radio_enabled_env && (
              <Row k="Deployment">RADIO_ENABLED=false overrides these settings</Row>
            )}
          </dl>
        )}
      </div>

      <fieldset className="space-y-2">
        <legend className="mb-1 text-sm font-medium">Mode</legend>
        <div className="grid gap-2 sm:grid-cols-3">
          {(
            [
              ["simulated", "Simulated", "Sample traffic, no hardware"],
              ["tcp", "MeshCore TCP", "Ethernet companion radio"],
              ["none", "None", "No radio connection"],
            ] as [RadioMode, string, string][]
          ).map(([m, title, sub]) => (
            <label
              key={m}
              className={cx(
                "flex cursor-pointer items-start gap-2 rounded-lg border p-3",
                mode === m ? "border-accent bg-accent-soft/40" : "border-line hover:bg-surface-2",
              )}
            >
              <input type="radio" name="radio-mode" checked={mode === m} onChange={() => setMode(m)} className="mt-1 accent-[var(--accent)]" />
              <span>
                <span className="block text-sm font-medium">{title}</span>
                <span className="block text-xs text-muted">{sub}</span>
              </span>
            </label>
          ))}
        </div>
      </fieldset>

      {mode === "tcp" && (
        <div className="space-y-3">
          <div className="grid grid-cols-[1fr_6.5rem] gap-3">
            <Field label="Radio IP address or hostname" htmlFor="radio-host" hint="Use the DHCP reservation for the radio.">
              <Input
                id="radio-host"
                placeholder="192.168.1.50"
                autoCapitalize="none"
                spellCheck={false}
                value={host}
                onChange={(e) => setHost(e.target.value)}
              />
            </Field>
            <Field label="TCP port" htmlFor="radio-port">
              <Input id="radio-port" inputMode="numeric" value={port} onChange={(e) => setPort(e.target.value)} />
            </Field>
          </div>
          <div className="flex flex-wrap items-center gap-3">
            <Button onClick={() => test.mutate()} disabled={!host.trim() || test.isPending}>
              <PlugZap className="size-4" aria-hidden /> {test.isPending ? "Testing…" : "Test reachability"}
            </Button>
            {test.data && (
              <span className={cx("text-sm", test.data.reachable ? "text-ok" : "text-danger")} role="status">
                {test.data.reachable ? "Reachable" : "Not reachable"} — {test.data.detail}
              </span>
            )}
          </div>
          <p className="text-xs text-muted">
            The reachability test only checks that the TCP port is open. The MeshCore TCP adapter has not yet been
            verified against real hardware; check the status above after saving.
          </p>
        </div>
      )}

      {mode === "simulated" && (
        <Field label="Average seconds between simulated messages" htmlFor="sim-interval" hint="0 turns off automatic traffic.">
          <Input
            id="sim-interval"
            inputMode="numeric"
            className="max-w-32"
            value={interval}
            onChange={(e) => setIntervalS(e.target.value)}
          />
        </Field>
      )}

      <ErrorText error={save.error ?? pause.error ?? simulate.error ?? test.error} />
      <div className="flex flex-wrap gap-2">
        <Button variant="primary" onClick={() => save.mutate()} disabled={!dirty || save.isPending}>
          {save.isPending ? "Saving…" : "Save and reconnect"}
        </Button>
        {cfg.data && cfg.data.mode !== "none" && (
          <Button onClick={() => pause.mutate(!cfg.data!.paused)} disabled={pause.isPending}>
            {cfg.data.paused ? <Play className="size-4" aria-hidden /> : <Pause className="size-4" aria-hidden />}
            {cfg.data.paused ? "Resume radio" : "Pause for maintenance"}
          </Button>
        )}
        {r?.state === "connected" && (
          <Link
            to="/settings/node"
            className="inline-flex min-h-11 items-center gap-2 rounded-lg border border-line bg-surface px-4 text-sm font-medium hover:bg-surface-2"
          >
            <SlidersHorizontal className="size-4" aria-hidden /> Configure node settings
          </Link>
        )}
        {r?.state === "connected" && r.is_simulated && (
          <Button onClick={() => simulate.mutate()} disabled={simulate.isPending}>
            <Sparkles className="size-4" aria-hidden /> Simulate incoming message
          </Button>
        )}
      </div>
    </Section>
  );
}

function DeviceSection() {
  const device = useQuery({ queryKey: ["device"], queryFn: () => api<Device>("/api/device") });
  const d = device.data;
  if (!d?.radio)
    return (
      <Section title="Device">
        <p className="text-sm text-muted">No radio has connected yet.</p>
      </Section>
    );
  const rf = d.radio.rf ?? {};
  return (
    <Section title="Device" description="Read-only information reported by the radio.">
      <dl className="divide-y divide-line">
        <Row k="Name">
          {d.radio.name} {d.radio.is_simulated && <Badge tone="warn">Simulated</Badge>}
        </Row>
        <Row k="Public key">
          <code className="break-all font-mono text-xs">{d.radio.public_key}</code>
        </Row>
        <Row k="Model">{String(d.radio.device_info.model ?? "—")}</Row>
        <Row k="Firmware">{String(d.radio.device_info.firmware ?? "—")}</Row>
        <Row k="RF">
          {rf.freq_mhz ? `${rf.freq_mhz} MHz · BW ${rf.bw_khz} kHz · SF${rf.sf} · CR${rf.cr} · ${rf.tx_power_dbm} dBm` : "—"}
        </Row>
        <Row k="Last connected">{formatDateTime(d.radio.last_connected_at)}</Row>
        <Row k="Contacts known">{d.contacts}</Row>
      </dl>
      <div>
        <h4 className="mb-1 text-sm font-medium">Channels</h4>
        <ul className="divide-y divide-line rounded-lg border border-line text-sm">
          {d.channels.map((c) => (
            <li key={`${c.slot}-${c.generation}`} className="flex items-center justify-between gap-2 px-3 py-2">
              <span>
                <span className="text-muted">Slot {c.slot}</span> · {c.name}
              </span>
              <span className="flex gap-1">
                {c.generation > 1 && <Badge>gen {c.generation}</Badge>}
                {!c.active && <Badge>archived</Badge>}
              </span>
            </li>
          ))}
          {d.channels.length === 0 && <li className="px-3 py-2 text-muted">No channels.</li>}
        </ul>
        <p className="mt-1 text-xs text-muted">Channel keys are never stored or shown by this app.</p>
      </div>
    </Section>
  );
}

function GapsSection() {
  const status = useStatus();
  const gaps = status.data?.gaps ?? [];
  return (
    <Section
      title="Collection gaps"
      description="Periods when the archive was not collecting. Messages sent during a gap may be missing — the radio's own buffer is finite."
    >
      {gaps.length === 0 ? (
        <p className="text-sm text-muted">No gaps recorded.</p>
      ) : (
        <ul className="divide-y divide-line text-sm">
          {gaps.map((g, i) => (
            <li key={i} className="flex flex-wrap justify-between gap-x-4 gap-y-0.5 py-2">
              <span>{g.reason}</span>
              <span className="text-muted">
                {formatDateTime(g.started_at)} → {g.open ? <Badge tone="warn">ongoing</Badge> : formatDateTime(g.ended_at)}
              </span>
            </li>
          ))}
        </ul>
      )}
    </Section>
  );
}

const OSM_DEFAULT: MapConfig = {
  tile_url: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
  attribution: "© OpenStreetMap contributors",
  max_zoom: 19,
};

function MapSection() {
  const qc = useQueryClient();
  const cfg = useQuery({ queryKey: ["map-settings"], queryFn: () => api<MapConfig>("/api/settings/map") });
  const [form, setForm] = useState<MapConfig>(OSM_DEFAULT);
  useEffect(() => {
    if (cfg.data) setForm(cfg.data);
  }, [cfg.data]);
  const save = useMutation({
    mutationFn: (body: MapConfig) => api<MapConfig>("/api/settings/map", { method: "PUT", json: body }),
    onSuccess: (saved) => {
      setForm(saved);
      qc.invalidateQueries({ queryKey: ["map-settings"] });
      qc.invalidateQueries({ queryKey: ["map"] });
    },
  });
  const dirty = cfg.data && JSON.stringify(cfg.data) !== JSON.stringify(form);
  return (
    <Section
      title="Map"
      description={
        <>
          Map tiles are loaded by your browser from this tile server; the server sees which areas you view. The
          default is <a className="text-accent underline" href="https://www.openstreetmap.org" target="_blank" rel="noopener">OpenStreetMap</a>{" "}
          (free, open data, light personal use). Point this at a self-hosted XYZ tile server for full privacy.
        </>
      }
    >
      <Field label="Tile URL template" htmlFor="tile-url" hint="https:// with {z}, {x} and {y} placeholders.">
        <Input
          id="tile-url"
          spellCheck={false}
          autoCapitalize="none"
          className="font-mono text-xs sm:text-xs"
          value={form.tile_url}
          onChange={(e) => setForm({ ...form, tile_url: e.target.value })}
        />
      </Field>
      <div className="grid gap-3 sm:grid-cols-[1fr_8rem]">
        <Field label="Attribution" htmlFor="tile-attr" hint="Required by most tile providers.">
          <Input id="tile-attr" value={form.attribution} onChange={(e) => setForm({ ...form, attribution: e.target.value })} />
        </Field>
        <Field label="Max zoom" htmlFor="tile-zoom">
          <Input
            id="tile-zoom"
            inputMode="numeric"
            value={String(form.max_zoom)}
            onChange={(e) => setForm({ ...form, max_zoom: Number(e.target.value) || 0 })}
          />
        </Field>
      </div>
      <ErrorText error={save.error} />
      <div className="flex flex-wrap gap-2">
        <Button variant="primary" onClick={() => save.mutate(form)} disabled={!dirty || save.isPending}>
          Save map settings
        </Button>
        <Button onClick={() => save.mutate(OSM_DEFAULT)} disabled={save.isPending}>
          Reset to OpenStreetMap
        </Button>
      </div>
    </Section>
  );
}

function AppearanceSection() {
  const [pref, setPref] = useState<ThemePref>(getThemePref());
  return (
    <Section title="Appearance">
      <div className="flex gap-2" role="radiogroup" aria-label="Theme">
        {(["system", "light", "dark"] as ThemePref[]).map((t) => (
          <button
            key={t}
            role="radio"
            aria-checked={pref === t}
            onClick={() => {
              setPref(t);
              applyTheme(t);
            }}
            className={cx(
              "min-h-11 flex-1 rounded-lg border text-sm capitalize",
              pref === t ? "border-accent bg-accent-soft/40 font-medium" : "border-line hover:bg-surface-2",
            )}
          >
            {t}
          </button>
        ))}
      </div>
    </Section>
  );
}

function AccountSection({ me }: { me: Me }) {
  return (
    <Section title="Account" description={`Signed in as ${me.username}.`}>
      <Link
        to="/account"
        className="inline-flex min-h-11 items-center gap-2 rounded-lg border border-line bg-surface px-4 text-sm font-medium hover:bg-surface-2"
      >
        <UserRound className="size-4" aria-hidden /> Manage username and password
      </Link>
    </Section>
  );
}

function DataSection() {
  const qc = useQueryClient();
  const status = useStatus();
  const del = useMutation({
    mutationFn: () => api<{ deleted_radios: number }>("/api/simulated-data", { method: "DELETE" }),
    onSuccess: () => qc.invalidateQueries(),
  });
  const simActive = status.data?.radio_config.mode === "simulated";
  return (
    <Section title="Data" description={`MeshCore Home v${status.data?.app.version ?? ""} · ${status.data?.database.messages ?? 0} messages archived.`}>
      <div className="flex flex-wrap gap-2">
        <a
          href="/api/export"
          className="inline-flex min-h-11 items-center gap-2 rounded-lg border border-line bg-surface px-4 text-sm font-medium hover:bg-surface-2"
        >
          <Download className="size-4" aria-hidden /> Export archive (JSON)
        </a>
        <Button
          variant="danger"
          disabled={simActive || del.isPending}
          title={simActive ? "Switch away from the simulated radio first" : undefined}
          onClick={() => {
            if (confirm("Delete all simulated conversations, contacts and messages? Real radio data is not affected.")) del.mutate();
          }}
        >
          <Trash2 className="size-4" aria-hidden /> Delete simulated data
        </Button>
      </div>
      {simActive && <p className="text-xs text-muted">To delete simulated data, switch the radio mode away from Simulated first.</p>}
      {del.data && <p className="text-sm text-ok">Simulated data deleted.</p>}
      <ErrorText error={del.error} />
    </Section>
  );
}
