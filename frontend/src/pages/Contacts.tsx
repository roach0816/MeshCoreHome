import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, useNavigate } from "react-router";
import { ChevronLeft, Copy, MessageSquare, Pencil, RefreshCw } from "lucide-react";
import { api, type Contact } from "../lib/api";
import { Badge, Button, ErrorText, IconButton, Input } from "../components/ui";
import { formatDateTime } from "../lib/util";

// MeshCore advert types.
const KIND: Record<number, string> = { 1: "Companion", 2: "Repeater", 3: "Room server", 4: "Sensor" };

export function Contacts() {
  const qc = useQueryClient();
  const navigate = useNavigate();
  const contacts = useQuery({ queryKey: ["contacts"], queryFn: () => api<Contact[]>("/api/contacts") });
  const refresh = useMutation({
    mutationFn: () => api<{ count: number }>("/api/contacts/refresh", { method: "POST" }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["contacts"] }),
  });
  const openDm = useMutation({
    mutationFn: (id: string) => api<{ conversation_id: string }>(`/api/contacts/${id}/conversation`, { method: "POST" }),
    onSuccess: async (r) => {
      await qc.invalidateQueries({ queryKey: ["conversations"] });
      navigate(`/c/${r.conversation_id}`);
    },
  });

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
        <h2 className="flex-1 px-1 text-base font-semibold">Contacts</h2>
        <Button onClick={() => refresh.mutate()} disabled={refresh.isPending}>
          <RefreshCw className={refresh.isPending ? "size-4 animate-spin" : "size-4"} aria-hidden />
          Refresh from radio
        </Button>
      </header>
      <div className="min-h-0 flex-1 overflow-y-auto p-3 md:p-6">
        <div className="mx-auto max-w-3xl space-y-3">
          <ErrorText error={refresh.error ?? openDm.error} />
          <p className="text-xs text-muted">
            Contacts are read from the home radio. The archive keeps contacts even after they are removed from the radio.
            Contact-card import is planned for a later version.
          </p>
          {contacts.isPending && <p className="text-sm text-muted">Loading…</p>}
          {contacts.data?.length === 0 && <p className="text-sm text-muted">No contacts yet.</p>}
          <ul className="divide-y divide-line overflow-hidden rounded-xl border border-line bg-surface">
            {contacts.data?.map((c) => (
              <ContactRow key={c.id} c={c} onMessage={() => openDm.mutate(c.id)} />
            ))}
          </ul>
        </div>
      </div>
    </div>
  );
}

function ContactRow({ c, onMessage }: { c: Contact; onMessage: () => void }) {
  const qc = useQueryClient();
  const [editing, setEditing] = useState(false);
  const [alias, setAlias] = useState(c.alias ?? "");
  const save = useMutation({
    mutationFn: () => api(`/api/contacts/${c.id}`, { method: "PATCH", json: { alias } }),
    onSuccess: () => {
      setEditing(false);
      qc.invalidateQueries({ queryKey: ["contacts"] });
    },
  });
  return (
    <li className="space-y-2 px-4 py-3">
      <div className="flex items-start gap-2">
        <div className="min-w-0 flex-1">
          <p className="flex flex-wrap items-center gap-1.5">
            <span className="truncate text-sm font-medium">{c.alias || c.name || "Unnamed"}</span>
            {c.alias && <span className="truncate text-xs text-muted">({c.name})</span>}
            <Badge>{KIND[c.kind] ?? `Type ${c.kind}`}</Badge>
            {!c.on_radio && <Badge>Not on radio</Badge>}
            {c.is_simulated && <Badge tone="warn">Simulated</Badge>}
          </p>
          <p className="mt-0.5 text-xs text-muted">Last advert: {formatDateTime(c.last_advert_at)}</p>
        </div>
        <IconButton label="Edit local alias" onClick={() => setEditing((v) => !v)}>
          <Pencil className="size-4" />
        </IconButton>
        {c.kind === 1 && (
          <IconButton label={`Message ${c.alias || c.name}`} onClick={onMessage}>
            <MessageSquare className="size-4" />
          </IconButton>
        )}
      </div>
      <div className="flex items-start gap-1">
        <code className="min-w-0 flex-1 break-all rounded-md bg-surface-2 px-2 py-1 font-mono text-[11px] text-muted">
          {c.public_key}
        </code>
        <IconButton label="Copy public key" onClick={() => navigator.clipboard?.writeText(c.public_key)}>
          <Copy className="size-4" />
        </IconButton>
      </div>
      {editing && (
        <form
          className="flex gap-2"
          onSubmit={(e) => {
            e.preventDefault();
            save.mutate();
          }}
        >
          <Input
            aria-label="Local alias"
            placeholder="Local alias (only shown here)"
            value={alias}
            maxLength={64}
            onChange={(e) => setAlias(e.target.value)}
          />
          <Button type="submit" variant="primary" disabled={save.isPending}>
            Save
          </Button>
        </form>
      )}
    </li>
  );
}
