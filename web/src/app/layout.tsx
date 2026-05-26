import type { Metadata } from "next";
import Link from "next/link";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";
import { StatusBar } from "@/components/StatusBar";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "Audio Archive",
  description: "Review and manage digitized audio recordings",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="en"
      className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col bg-background text-foreground font-sans">
        <header className="border-b border-neutral-200 dark:border-neutral-800 px-6 py-3 flex items-center gap-6">
          <Link href="/" className="text-base font-semibold tracking-tight">
            Audio Archive
          </Link>
          <nav className="flex items-center gap-4 text-sm text-neutral-600 dark:text-neutral-400">
            <Link href="/" className="hover:text-foreground">
              Recordings
            </Link>
            <Link href="/search" className="hover:text-foreground">
              Search
            </Link>
          </nav>
          <div className="ml-auto">
            <StatusBar />
          </div>
        </header>
        <main className="flex-1 px-6 py-6">{children}</main>
      </body>
    </html>
  );
}
