-- Run this once in the Supabase SQL Editor for the HealthDB project
-- (https://supabase.com/dashboard/project/thgawuqcogugzurrijkp/sql/new)

create table if not exists tasks (
  id bigint generated always as identity primary key,
  title text not null,
  notes text,
  status text not null default 'todo' check (status in ('todo', 'in_progress', 'done')),
  priority text not null default 'medium' check (priority in ('low', 'medium', 'high')),
  due_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Same single-user trust model as `parameters` / `measurements`:
-- access is gated client-side by the allowed_users login check, not by RLS.
alter table tasks disable row level security;
