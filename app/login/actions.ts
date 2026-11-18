"use server";
import { redirect } from "next/navigation";
import { z } from "zod";
import { createClient } from "@/lib/supabase/server";

export async function signIn(_prev: string | null, fd: FormData): Promise<string | null> {
  const parsed = z.object({ email: z.string().trim().email(), password: z.string().min(1).max(200) }).safeParse({
    email: fd.get("email"),
    password: fd.get("password"),
  });
  if (!parsed.success) return "Enter your email and password.";
  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword(parsed.data);
  // Same message for unknown user and wrong password (no account enumeration).
  if (error) {
    if (error.status === 429) return "Too many attempts. Wait a minute and try again.";
    if (error.name === "AuthRetryableFetchError" || !error.status) return "Cannot reach the server. Check the internet connection and try again.";
    return "Email or password is incorrect.";
  }
  redirect("/");
}
