import { Page, Notice } from "@/components/ui";

export default function NoOutlet() {
  return (
    <Page title="No outlet yet">
      <Notice tone="warn">Your login is not linked to an outlet. Ask the owner to add you.</Notice>
    </Page>
  );
}
