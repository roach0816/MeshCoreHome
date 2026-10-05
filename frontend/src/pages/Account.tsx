import { useState, type ReactNode } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { LogOut } from "lucide-react";
import { api, type Me } from "../lib/api";
import { Button, ErrorText, Field, Input } from "../components/ui";
import { Dialog } from "../components/Dialog";

function Section({ title, description, children }: { title: string; description?: ReactNode; children: ReactNode }) {
  return (
    <section className="border-t border-line pt-4">
      <h3 className="text-sm font-semibold">{title}</h3>
      {description && <p className="mt-0.5 text-xs text-muted">{description}</p>}
      <div className="mt-3 space-y-3">{children}</div>
    </section>
  );
}

/** Account settings, opened from the username at the bottom of the sidebar. */
export function AccountDialog({ me, onClose }: { me: Me; onClose: () => void }) {
  const qc = useQueryClient();
  const logout = useMutation({
    mutationFn: () => api("/api/auth/logout", { method: "POST" }),
    onSettled: () => {
      qc.clear();
      location.assign("/login");
    },
  });

  return (
    <Dialog title="Account" onClose={onClose}>
      <div className="space-y-4">
        <div className="flex items-center gap-3">
          <span
            aria-hidden
            className="flex size-12 shrink-0 items-center justify-center rounded-full bg-accent-soft text-lg font-semibold uppercase text-accent"
          >
            {me.username.slice(0, 1)}
          </span>
          <div className="min-w-0 flex-1">
            <p className="truncate font-semibold">{me.username}</p>
            <p className="truncate text-sm text-muted">Owner of {me.home_name}</p>
          </div>
          <Button variant="ghost" onClick={() => logout.mutate()} disabled={logout.isPending}>
            <LogOut className="size-4" aria-hidden /> Sign out
          </Button>
        </div>
        <UsernameSection me={me} />
        <PasswordSection />
      </div>
    </Dialog>
  );
}

function UsernameSection({ me }: { me: Me }) {
  const qc = useQueryClient();
  const [username, setUsername] = useState(me.username);
  const [password, setPassword] = useState("");
  const [done, setDone] = useState(false);
  const valid = /^[A-Za-z0-9_.@-]+$/.test(username) && username !== me.username;
  const save = useMutation({
    mutationFn: () => api<Me>("/api/auth/username", { method: "PUT", json: { username, current_password: password } }),
    onSuccess: (next) => {
      qc.setQueryData(["me"], next);
      setPassword("");
      setDone(true);
    },
  });
  return (
    <Section title="Username" description="Used to sign in. Your current password is required to change it.">
      <form
        className="space-y-3"
        onSubmit={(e) => {
          e.preventDefault();
          setDone(false);
          if (valid && password) save.mutate();
        }}
      >
        <div className="grid gap-3 sm:grid-cols-2">
          <Field
            label="New username"
            htmlFor="acct-username"
            error={username && !/^[A-Za-z0-9_.@-]+$/.test(username) ? "Letters, numbers and . _ @ - only" : null}
          >
            <Input
              id="acct-username"
              autoComplete="username"
              autoCapitalize="none"
              spellCheck={false}
              maxLength={64}
              value={username}
              onChange={(e) => setUsername(e.target.value)}
            />
          </Field>
          <Field label="Current password" htmlFor="acct-username-pw">
            <Input
              id="acct-username-pw"
              type="password"
              autoComplete="current-password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
            />
          </Field>
        </div>
        <ErrorText error={save.error} />
        {done && (
          <p className="text-sm text-ok" role="status">
            Username changed. Use it the next time you sign in.
          </p>
        )}
        <Button type="submit" variant="primary" disabled={!valid || !password || save.isPending}>
          Change username
        </Button>
      </form>
    </Section>
  );
}

function PasswordSection() {
  const [current, setCurrent] = useState("");
  const [next, setNext] = useState("");
  const [confirm, setConfirm] = useState("");
  const [done, setDone] = useState(false);
  const mismatch = confirm.length > 0 && confirm !== next;
  const change = useMutation({
    mutationFn: () => api("/api/auth/password", { json: { current_password: current, new_password: next } }),
    onSuccess: () => {
      setCurrent("");
      setNext("");
      setConfirm("");
      setDone(true);
    },
  });
  return (
    <Section title="Password" description="At least 10 characters. Changing it signs out every other browser.">
      <form
        className="space-y-3"
        onSubmit={(e) => {
          e.preventDefault();
          setDone(false);
          change.mutate();
        }}
      >
        <Field label="Current password" htmlFor="acct-cur-pw">
          <Input
            id="acct-cur-pw"
            type="password"
            autoComplete="current-password"
            value={current}
            onChange={(e) => setCurrent(e.target.value)}
          />
        </Field>
        <div className="grid gap-3 sm:grid-cols-2">
          <Field
            label="New password"
            htmlFor="acct-new-pw"
            error={next.length > 0 && next.length < 10 ? "Use at least 10 characters" : null}
          >
            <Input
              id="acct-new-pw"
              type="password"
              autoComplete="new-password"
              value={next}
              onChange={(e) => setNext(e.target.value)}
            />
          </Field>
          <Field label="Confirm new password" htmlFor="acct-new-pw2" error={mismatch ? "Passwords do not match" : null}>
            <Input
              id="acct-new-pw2"
              type="password"
              autoComplete="new-password"
              value={confirm}
              onChange={(e) => setConfirm(e.target.value)}
            />
          </Field>
        </div>
        <ErrorText error={change.error} />
        {done && (
          <p className="text-sm text-ok" role="status">
            Password changed. Other browsers have been signed out.
          </p>
        )}
        <Button
          type="submit"
          variant="primary"
          disabled={!current || next.length < 10 || next !== confirm || change.isPending}
        >
          Change password
        </Button>
      </form>
    </Section>
  );
}
