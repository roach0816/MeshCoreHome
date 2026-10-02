import { useQuery } from "@tanstack/react-query";
import { api, type SetupStatus } from "./api";

export function useSetupStatus() {
  return useQuery({
    queryKey: ["setup-status"],
    queryFn: () => api<SetupStatus>("/api/setup/status"),
    staleTime: Infinity,
  });
}
