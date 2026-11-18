"use client";
import { useRef, useState, useTransition } from "react";
import { btnPrimary, btnDanger } from "@/components/ui";
import type { ActionResult } from "@/lib/action";

/**
 * Form bound to a server action. Shows the result inline, asks for confirmation on sensitive
 * operations (SRS §9.1 "clear confirmation before important submissions"), resets on success.
 */
export function ActionForm({
  action,
  children,
  submit,
  confirm,
  danger,
  className = "",
  resetOnSuccess = true,
  inline = false,
}: {
  action: (fd: FormData) => Promise<ActionResult>;
  children?: React.ReactNode;
  submit: string;
  confirm?: string;
  danger?: boolean;
  className?: string;
  resetOnSuccess?: boolean;
  inline?: boolean;
}) {
  const [pending, start] = useTransition();
  const [res, setRes] = useState<ActionResult | null>(null);
  const ref = useRef<HTMLFormElement>(null);
  return (
    <form
      ref={ref}
      className={`${inline ? "flex flex-wrap items-end gap-2" : "space-y-3"} ${className}`}
      onSubmit={(e) => {
        e.preventDefault();
        if (confirm && !window.confirm(confirm)) return;
        const fd = new FormData(e.currentTarget);
        start(async () => {
          const r = await action(fd);
          setRes(r);
          if (r.ok && resetOnSuccess) ref.current?.reset();
        });
      }}
    >
      {children}
      <div className={inline ? "" : "flex flex-wrap items-center gap-3"}>
        <button type="submit" disabled={pending} className={danger ? btnDanger : btnPrimary}>
          {pending ? "Saving…" : submit}
        </button>
        {!inline && res && (
          <span role={res.ok ? "status" : "alert"} className={`text-sm ${res.ok ? "text-emerald-700" : "text-rose-700"}`}>
            {res.ok ? res.message ?? "Saved." : res.error}
          </span>
        )}
      </div>
      {inline && res && !res.ok && <p role="alert" className="w-full text-sm text-rose-700">{res.error}</p>}
      {inline && res?.ok && res.message && <p role="status" className="w-full text-sm text-emerald-700">{res.message}</p>}
    </form>
  );
}
