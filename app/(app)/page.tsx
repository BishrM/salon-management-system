import { redirect } from "next/navigation";
import { getContext } from "@/lib/session";
import { Page, Notice } from "@/components/ui";

export default async function Home({ searchParams }: { searchParams: Promise<{ denied?: string }> }) {
  const ctx = await getContext();
  const { denied } = await searchParams;
  if (!ctx.outlet) redirect("/no-outlet");
  if (denied) {
    return (
      <Page title="Not available">
        <Notice tone="warn">Your role does not include that screen. Use the menu above.</Notice>
      </Page>
    );
  }
  redirect(ctx.can("reports.read") ? "/dashboard" : ctx.can("entries.record") ? "/register" : "/closing");
}
