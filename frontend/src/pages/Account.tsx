import { useState, type ReactNode } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Link } from "react-router";
import { ChevronLeft, ExternalLink, LogOut } from "lucide-react";
import { api, type Me } from "../lib/api";
import { Button, Card, ErrorText, Field, Input } from "../components/ui";
import { useSetupStatus } from "../lib/queries";

function Section({ title, description, children }: { title: string; description?: ReactNode; children: ReactNode }) {
  return (
    <Card className="p-4 sm:p-5">
      <h3 className="text-base font-semibold">{title}</h3>
      {description && <p className="mt-0.5 text-sm text-muted">{description}</p>}
      <div className="mt-4 space-y-4">{children}</div>
    </Card>
  );
}

export function Account({ me }: { me: Me }) {
  const qc = useQueryClient();
  const meta = useSetupStatus();
  const logout = useMutation({
    mutationFn: () => api("/api/auth/logout", { method: "POST" }),
    onSettled: () => {
      qc.clear();
      location.assign("/login");
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
        <h2 className="flex-1 px-1 py-2 text-base font-semibold">Account</h2>
      </header>
      <div className="min-h-0 flex-1 overflow-y-auto p-3 md:p-6">
        <div className="mx-auto max-w-2xl space-y-4">
          <Card className="flex items-center gap-4 p-4 sm:p-5">
            <span
              aria-hidden
              className="flex size-14 shrink-0 items-center justify-center rounded-full bg-accent-soft text-xl font-semibold uppercase text-accent"
            >
              {me.username.slice(0, 1)}
            </span>
            <div className="min-w-0 flex-1">
              <p className="truncate text-lg font-semibold">{me.username}</p>
              <p className="text-sm text-muted">Owner of {me.home_name}</p>
            </div>
            <Button variant="ghost" onClick={() => logout.mutate()} disabled={logout.isPending}>
              <LogOut className="size-4" aria-hidden /> Sign out
            </Button>
          </Card>
          <UsernameSection me={me} />
          <PasswordSection />
          <Section title="About">
            <p className="text-sm">
              MeshCore Home v{meta.data?.version ?? "…"}
              {meta.data?.release_url && (
                <>
                  {" · "}
                  <a
                    href={meta.data.release_url}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="inline-flex items-center gap-1 text-accent underline"
                  >
                    What's new in this version <ExternalLink className="size-3.5" aria-hidden />
                  </a>
                </>
              )}
            </p>
          </Section>
        </div>
      </div>
    </div>
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
