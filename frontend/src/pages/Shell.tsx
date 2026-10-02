import { useQuery } from "@tanstack/react-query";
import { MessagesSquare, Settings as SettingsIcon, Users } from "lucide-react";
import { NavLink, Route, Routes, useLocation } from "react-router";
import { api, type Me, type Status } from "../lib/api";
import { useRealtime } from "../lib/realtime";
import { cx } from "../lib/util";
import { ConversationList } from "../components/ConversationList";
import { StatusPill } from "../components/StatusPill";
import { Thread } from "./Thread";
import { Contacts } from "./Contacts";
import { Settings } from "./Settings";

export function useStatus() {
  return useQuery({ queryKey: ["status"], queryFn: () => api<Status>("/api/status"), refetchInterval: 15000 });
}

function NavItem({ to, label, icon: Icon }: { to: string; label: string; icon: typeof Users }) {
  return (
    <NavLink
      to={to}
      end={to === "/"}
      aria-label={label}
      title={label}
      className={({ isActive }) =>
        cx(
          "inline-flex size-11 items-center justify-center rounded-lg transition-colors",
          isActive ? "bg-accent-soft text-accent" : "text-muted hover:bg-surface-2 hover:text-ink",
        )
      }
    >
      <Icon className="size-5" aria-hidden />
    </NavLink>
  );
}

function EmptyPane() {
  return (
    <div className="hidden h-full flex-col items-center justify-center gap-2 p-8 text-center md:flex">
      <MessagesSquare className="size-10 text-muted" aria-hidden />
      <p className="text-sm text-muted">Select a conversation</p>
    </div>
  );
}

export function Shell({ me }: { me: Me }) {
  const socket = useRealtime(true);
  const status = useStatus();
  const { pathname } = useLocation();
  const atRoot = pathname === "/";

  return (
    <div className="app-height flex overflow-hidden bg-bg">
      <aside
        className={cx(
          "flex h-full w-full flex-col border-line bg-surface md:w-80 md:border-r lg:w-96",
          !atRoot && "hidden md:flex",
        )}
        aria-label="Conversations"
      >
        <header className="flex items-center gap-2 border-b border-line px-3 py-2">
          <div className="min-w-0 flex-1 pl-1">
            <h1 className="truncate text-base font-semibold">{me.home_name}</h1>
            <StatusPill status={status.data} socket={socket} />
          </div>
          <nav className="flex items-center gap-1" aria-label="Main">
            <NavItem to="/" label="Chats" icon={MessagesSquare} />
            <NavItem to="/contacts" label="Contacts" icon={Users} />
            <NavItem to="/settings" label="Settings" icon={SettingsIcon} />
          </nav>
        </header>
        <ConversationList />
      </aside>
      <main className={cx("h-full min-w-0 flex-1", atRoot && "hidden md:block")}>
        <Routes>
          <Route index element={<EmptyPane />} />
          <Route path="c/:id" element={<Thread status={status.data} />} />
          <Route path="contacts" element={<Contacts />} />
          <Route path="settings" element={<Settings me={me} />} />
          <Route path="*" element={<EmptyPane />} />
        </Routes>
      </main>
    </div>
  );
}
