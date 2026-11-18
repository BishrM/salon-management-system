"use client";
import { useActionState } from "react";
import { signIn } from "./actions";
import { btnPrimary, input, labelCls } from "@/components/ui";

export function LoginForm() {
  const [state, action, pending] = useActionState(signIn, null as string | null);
  return (
    <form action={action} className="space-y-4">
      <div>
        <label htmlFor="email" className={labelCls}>Email</label>
        <input id="email" name="email" type="email" autoComplete="username" required className={input} />
      </div>
      <div>
        <label htmlFor="password" className={labelCls}>Password</label>
        <input id="password" name="password" type="password" autoComplete="current-password" required className={input} />
      </div>
      {state && <p role="alert" className="text-sm text-rose-700">{state}</p>}
      <button disabled={pending} className={`${btnPrimary} w-full`}>{pending ? "Signing in…" : "Sign in"}</button>
    </form>
  );
}
