"use client";
import { btnSecondary } from "@/components/ui";

export function PrintButton({ label = "Print / save as PDF" }: { label?: string }) {
  return <button className={btnSecondary} onClick={() => window.print()}>{label}</button>;
}
