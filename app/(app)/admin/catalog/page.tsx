import type { Metadata } from "next";
import { requirePermission } from "@/lib/session";
import { Page, Card, input, labelCls } from "@/components/ui";
import { ActionForm } from "@/components/action-form";
import { upsertProduct } from "../../actions";
import { rupees } from "@/lib/money";

export const metadata: Metadata = { title: "Product catalogue" };

export default async function Catalog() {
  const { supabase, outlet } = await requirePermission("catalog.manage");
  const { data: products } = await supabase.from("product_catalog").select("*").eq("outlet_id", outlet.id).order("name");
  return (
    <Page title="Product catalogue">
      <Card title="Add product">
        <ActionForm action={upsertProduct} submit="Add product" inline>
          <input type="hidden" name="outlet" value={outlet.id} />
          <div><label className={labelCls} htmlFor="pn">Name</label><input id="pn" name="name" className={input} required maxLength={120} /></div>
          <div><label className={labelCls} htmlFor="pp">Usual price (₹)</label><input id="pp" name="price" inputMode="numeric" className={input} required /></div>
        </ActionForm>
      </Card>
      <Card title="Products">
        <ul className="divide-y divide-slate-100">
          {(products ?? []).map((p) => (
            <li key={p.id} className="py-3">
              <ActionForm action={upsertProduct} submit="Save" inline resetOnSuccess={false}>
                <input type="hidden" name="outlet" value={outlet.id} /><input type="hidden" name="product" value={p.id} />
                <div><label className={labelCls} htmlFor={`n-${p.id}`}>Name</label><input id={`n-${p.id}`} name="name" defaultValue={p.name} className={input} required /></div>
                <div><label className={labelCls} htmlFor={`p-${p.id}`}>Price (₹) · now {rupees(p.default_price)}</label><input id={`p-${p.id}`} name="price" defaultValue={p.default_price / 100} inputMode="numeric" className={input} required /></div>
                <div><label className={labelCls} htmlFor={`a-${p.id}`}>Status</label>
                  <select id={`a-${p.id}`} name="active" defaultValue={String(p.active)} className={input}><option value="true">On sale</option><option value="false">Hidden</option></select></div>
              </ActionForm>
            </li>
          ))}
        </ul>
        {!(products ?? []).length && <p className="text-sm text-slate-500">No products yet.</p>}
      </Card>
    </Page>
  );
}
