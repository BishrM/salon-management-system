import type { Metadata } from "next";
import { LoginForm } from "./login-form";

export const metadata: Metadata = { title: "Sign in" };

export default function LoginPage() {
  return (
    <main className="flex min-h-dvh items-center justify-center px-4">
      <div className="w-full max-w-sm rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
        <h1 className="text-2xl font-semibold">SalonOps</h1>
        <p className="mb-5 mt-1 text-sm text-slate-600">Sign in with the login the owner gave you.</p>
        <LoginForm />
      </div>
    </main>
  );
}
