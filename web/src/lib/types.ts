export interface Recording {
  id: number;
  slug: string;
  date: string | null;
  speaker: string | null;
  title: string | null;
  series: string | null;
  master_path: string;
  prep_path: string | null;
  duration_ms: number | null;
  sample_rate: number | null;
  channels: number | null;
  format: string | null;
  created_at: string;
  updated_at: string;
  synced_at: string | null;
  remanence_catalog_number: string | null;
  group_id: string | null;
  group_title: string | null;
  source_path: string | null;
  context: string | null;
  approved_at: string | null;
}

export interface Job {
  id: number;
  recording_id: number;
  type: string;
  status: string;
  attempt: number;
  max_retries: number;
  error: string | null;
  model: string | null;
  created_at: string;
  started_at: string | null;
  finished_at: string | null;
}

export interface Transcript {
  id: number;
  recording_id: number;
  full_text: string | null;
  segments: string | null;
  language: string | null;
  model_used: string | null;
  created_at: string;
}

export interface Segment {
  start: number;
  end: number;
  text: string;
}

export interface Summary {
  id: number;
  recording_id: number;
  recording_type: string | null;
  summary_short: string | null;
  metadata: string;
  model_used: string | null;
  created_at: string;
}

export interface RecordingSummaryMeta {
  recording_type: string;
  type_confidence: string;
  summary_short: string;
  summary_long: string;
  suggested_title: string;
  main_topics: string[];
  themes: string[];
  tags: string[];
  people: string[];
  places: string[];
  organizations: string[];
  dates_mentioned: string[];
  estimated_era: string;
  estimated_date: string;
  notable_quotes: string[];
  mood: string;
  speakers: string[];
  action_items: string[];
  type_specific: Record<string, unknown>;
}

export interface JobCounts {
  pending: number;
  running: number;
  complete: number;
  failed: number;
}
