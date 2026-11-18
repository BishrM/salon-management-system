"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";

export function NavLinks({ links }: { links: { href: string; label: string }[] }) {
  const path = usePathname();
  return (
    <nav aria-label="Main" className="-mx-1 flex w-full gap-1 overflow-x-auto pb-1">
      {links.map((l) => {
        const active = path === l.href || path.startsWith(l.href + "/");
        return (
          <Link
            key={l.href}
            href={l.href}
            aria-current={active ? "page" : undefined}
            className={`whitespace-nowrap rounded-md px-3 py-2 text-sm font-medium ${active ? "bg-brand-50 text-brand-800" : "text-slate-700 hover:bg-slate-100"}`}
          >
            {l.label}
          </Link>
        );
      })}
    </nav>
  );
}
