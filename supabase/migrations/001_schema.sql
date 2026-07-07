-- LevelSpot schema v1. PostGIS for the tight-radius personal-pitch match; RLS everywhere.
-- Free/Pro is enforced at the DATA layer (per the build prompt): sun/view headings live in a
-- separate table whose SELECT policy requires an active entitlement — not just hidden in UI.

create extension if not exists postgis;

-- ---------- Reference data (public read; seeded by 002, maintained via gen-seed.js) ----------
create table if not exists vehicle_generations (
  gen_id            text primary key,
  make              text not null,
  model             text not null,
  generation        text not null,
  year_from         int,
  year_to           int,                -- null = still in production
  badges            text,               -- same-vehicle badge twins, human-readable
  wheelbases_mm     int[] not null,
  track_front_mm    int,                -- null = TBC, do not offer as a preset
  track_rear_mm     int,
  track_confidence  text not null,      -- high | med | tbc
  camper_relevance  text not null,
  notes             text
);

create table if not exists chassis_types (
  chassis_id            text primary key,
  chassis_type          text not null,
  fits_platforms        text,
  wheelbase_range_mm    text,
  front_track_mm        int,
  rear_track_mm_min     int,
  rear_track_mm_max     int,
  rear_track_confidence text,
  axle_config           text not null,  -- single | tandem
  notes                 text
);

create table if not exists ramp_profiles (
  profile_id text primary key,
  name       text not null,
  steps_mm   int[] not null,
  pro        boolean not null default false
);

alter table vehicle_generations enable row level security;
alter table chassis_types       enable row level security;
alter table ramp_profiles       enable row level security;
create policy "reference readable by all" on vehicle_generations for select using (true);
create policy "reference readable by all" on chassis_types       for select using (true);
create policy "reference readable by all" on ramp_profiles       for select using (true);

-- ---------- Entitlements ----------
-- Written ONLY by the service role (per-platform receipt verification lands in an Edge
-- Function later: StoreKit 2 on iOS, Play Billing on Android — one row per user either way,
-- so Pro bought on iPhone works on an Android tablet).
create table if not exists user_entitlements (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  is_pro     boolean not null default false,
  source     text,                      -- 'appstore' | 'play' | 'promo'
  updated_at timestamptz not null default now()
);
alter table user_entitlements enable row level security;
create policy "own entitlement readable" on user_entitlements for select using (auth.uid() = user_id);
-- no insert/update/delete policies: client cannot write its own entitlement.

create or replace function is_pro(uid uuid) returns boolean
language sql stable security definer set search_path = public as
$$ select coalesce((select is_pro from user_entitlements where user_id = uid), false) $$;

-- ---------- User vehicle config (synced copy of local setup) ----------
create table if not exists vehicles (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references auth.users (id) on delete cascade,
  gen_id              text references vehicle_generations (gen_id),
  wheelbase_mm        int not null,
  track_front_mm      int not null,
  track_rear_mm       int not null,
  chassis_kind        text not null default 'standard',  -- standard | alko | measured
  living_side         text not null,                     -- front | driver | rear | passenger (never nearside/offside)
  ramp_profile_id     text not null default 'default' references ramp_profiles (profile_id),
  custom_steps_mm     int[],
  using_typical_dims  boolean not null default true,     -- drives the ESTIMATED tag
  updated_at          timestamptz not null default now()
);
alter table vehicles enable row level security;
create policy "own vehicles" on vehicles for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ---------- Personal pitch history (private; never shared between users) ----------
create table if not exists pitches (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users (id) on delete cascade,
  location       geography(point, 4326) not null,
  level_heading  int,                    -- degrees, the parking heading that was level
  corner_fl_mm   real, corner_fr_mm real, corner_rl_mm real, corner_rr_mm real,
  rating         int check (rating between 1 and 5),
  site_name      text,
  visited_at     timestamptz not null default now()
);
create index if not exists pitches_location_idx on pitches using gist (location);
alter table pitches enable row level security;
create policy "own pitches" on pitches for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Pro-only per-pitch data, split out so the free tier can SEE THAT IT EXISTS (via the
-- boolean flags in pitches_with_flags) but cannot read the values — locked, not hidden.
create table if not exists pitch_pro_data (
  pitch_id     uuid primary key references pitches (id) on delete cascade,
  sun_heading  int,
  view_heading int
);
alter table pitch_pro_data enable row level security;
create policy "pro data readable when entitled" on pitch_pro_data for select
  using (is_pro(auth.uid()) and exists (select 1 from pitches p where p.id = pitch_id and p.user_id = auth.uid()));
create policy "pro data writable by owner" on pitch_pro_data for insert
  with check (exists (select 1 from pitches p where p.id = pitch_id and p.user_id = auth.uid()));
create policy "pro data updatable by owner" on pitch_pro_data for update
  using (exists (select 1 from pitches p where p.id = pitch_id and p.user_id = auth.uid()));

create or replace view pitches_with_flags
with (security_invoker = true) as
select p.*, (d.sun_heading is not null) as has_sun, (d.view_heading is not null) as has_view
from pitches p left join pitch_pro_data d on d.pitch_id = p.id;

-- Tight-radius match against the caller's OWN history only.
create or replace function nearby_pitches(lat double precision, lon double precision, radius_m double precision default 25)
returns setof pitches_with_flags
language sql stable security invoker as $$
  select * from pitches_with_flags
  where user_id = auth.uid()
    and st_dwithin(location, st_setsrid(st_makepoint(lon, lat), 4326)::geography, radius_m)
  order by visited_at desc
$$;
