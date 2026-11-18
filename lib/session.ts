import "server-only";
import { cache } from "react";
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export type Role = "owner" | "manager" | "head" | "counter";
export type OutletRef = { id: string; name: string };

export const OUTLET_COOKIE = "salonops_outlet";

/**
 * The signed-in user, their outlets and their permissions in the selected outlet.
 * Permissions come from the database on every request (Rev 6 §4: never from JWT claims).
 */
export const getContext = cache(async () => {
  const supabase = await createClient();
  const { data: claims } = await supabase.auth.getClaims();
  const userId = claims?.claims?.sub as string | undefined;
  if (!userId) redirect("/login");

  const [{ data: profile }, { data: outlets }] = await Promise.all([
    supabase.from("profiles").select("id, full_name").eq("id", userId).single(),
    supabase.from("outlets").select("id, name, timezone, day_cutoff, denominations").order("name"),
  ]);
  const list = outlets ?? [];
  const chosen = (await cookies()).get(OUTLET_COOKIE)?.value;
  const outlet = list.find((o) => o.id === chosen) ?? list[0] ?? null;

  let permissions: string[] = [];
  let today: string | null = null;
  if (outlet) {
    const [{ data: perms }, { data: bd }] = await Promise.all([
      supabase.rpc("my_permissions", { p_outlet: outlet.id }),
      outlet.day_cutoff ? supabase.rpc("current_business_date", { p_outlet: outlet.id }) : Promise.resolve({ data: null }),
    ]);
    permissions = (perms as string[]) ?? [];
    today = (bd as string | null) ?? null;
  }
  const can = (p: string) => permissions.includes(p);
  return {
    supabase,
    userId,
    userName: profile?.full_name ?? "",
    outlets: list.map((o) => ({ id: o.id, name: o.name })) as OutletRef[],
    outlet: outlet as null | {
      id: string; name: string; timezone: string; day_cutoff: string | null; denominations: number[];
    },
    permissions,
    can,
    /** Current business date of the selected outlet (null until the cutoff is set). */
    today,
  };
});

/** Context that requires an outlet and a permission, else shows a friendly page via redirect. */
export async function requirePermission(permission: string) {
  const ctx = await getContext();
  if (!ctx.outlet) redirect("/no-outlet");
  if (!ctx.can(permission)) redirect("/?denied=1");
  return ctx as typeof ctx & { outlet: NonNullable<typeof ctx.outlet> };
}
