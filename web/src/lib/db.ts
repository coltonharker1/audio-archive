import Database from "better-sqlite3";
import path from "path";
import os from "os";

const DB_PATH =
  process.env.ARCHIVE_DB_PATH ||
  path.join(os.homedir(), ".audio-archive", "archive.db");

let db: Database.Database | null = null;

function open(): Database.Database {
  if (!db) {
    db = new Database(DB_PATH);
    db.pragma("journal_mode = WAL");
    db.pragma("busy_timeout = 5000");
  }
  return db;
}

export function getDb(): Database.Database {
  return open();
}

export function getWriteDb(): Database.Database {
  return open();
}

export const ARCHIVE_ROOT =
  process.env.ARCHIVE_ROOT || path.join(os.homedir(), ".audio-archive");
