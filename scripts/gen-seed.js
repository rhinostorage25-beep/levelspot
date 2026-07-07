// Generates the vehicle reference data for both sides of the stack from the researched CSVs:
//   Data/van_dimensions_levelspot_v2.csv  + Data/coachbuilt_chassis_v1.csv
//     -> supabase/migrations/002_seed_reference.sql   (Postgres seed)
//     -> LevelSpot/Resources/vehicle_reference.json   (bundled offline copy for the app)
// Run:  node scripts/gen-seed.js   (from the Code/ directory)
// Re-run whenever the CSVs change; both outputs are committed, not hand-edited.

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const DATA = path.resolve(ROOT, '..', 'Data');

function parseCSV(text) {
  const rows = [];
  let row = [], field = '', inQuotes = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (inQuotes) {
      if (ch === '"' && text[i + 1] === '"') { field += '"'; i++; }
      else if (ch === '"') inQuotes = false;
      else field += ch;
    } else if (ch === '"') inQuotes = true;
    else if (ch === ',') { row.push(field); field = ''; }
    else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && text[i + 1] === '\n') i++;
      row.push(field); field = '';
      if (row.some(f => f !== '')) rows.push(row);
      row = [];
    } else field += ch;
  }
  if (field !== '' || row.length) { row.push(field); if (row.some(f => f !== '')) rows.push(row); }
  const header = rows.shift();
  return rows.map(r => Object.fromEntries(header.map((h, i) => [h, r[i] ?? ''])));
}

const gens = parseCSV(fs.readFileSync(path.join(DATA, 'van_dimensions_levelspot_v2.csv'), 'utf8'));
const chassis = parseCSV(fs.readFileSync(path.join(DATA, 'coachbuilt_chassis_v1.csv'), 'utf8'));

// Ramp profiles per the design brief (heights in mm; branded profiles are Pro-gated).
const rampProfiles = [
  { id: 'default', name: 'Default steps', steps_mm: [44, 78, 112], pro: false },
  { id: 'thule',   name: 'Thule',          steps_mm: [44, 78, 112], pro: true },
  { id: 'milenco', name: 'Milenco Trident', steps_mm: [40, 110, 170], pro: true },
  { id: 'vonhaus', name: 'VonHaus',         steps_mm: [40, 70, 100], pro: true },
  { id: 'fiamma',  name: 'Fiamma',          steps_mm: [40, 65, 90, 115], pro: true },
];

// The six Setup presets from the design handoff, mapped to the generation rows whose
// dimensions they use. Where a preset spans generations with a TBC track (T5, W906),
// it deliberately uses the confirmed sibling's figures — readings carry the ESTIMATED
// tag regardless, and the TBC research items remain open in Data/van_dimensions_README_v2.md.
const setupPresets = [
  { id: 'tt6',      name: 'VW T5 / T6 / T6.1',          silhouette: 'lowtop',  gen_id: 'transporter-t6' },
  { id: 'transit',  name: 'Ford Transit Custom',         silhouette: 'compact', gen_id: 'transit-custom-g2' },
  { id: 'ducato',   name: 'Fiat Ducato',                 silhouette: 'hightop', gen_id: 'ducato-x250-x290-s8' },
  { id: 'sprinter', name: 'Mercedes Sprinter / Crafter', silhouette: 'hightop', gen_id: 'sprinter-w907' },
  { id: 'trafic',   name: 'Renault Trafic',              silhouette: 'compact', gen_id: 'trafic-3' },
  { id: 'vivaro',   name: 'Vauxhall Vivaro',             silhouette: 'compact', gen_id: 'vivaro-c-emp2' },
];

const num = v => (v === '' || v == null ? null : Number(v));
const yearsOf = y => {
  const m = y.match(/^(\d{4})-(\d{4}|present)$/);
  return m ? { from: Number(m[1]), to: m[2] === 'present' ? null : Number(m[2]) } : { from: null, to: null };
};

const genRows = gens.map(g => {
  const { from, to } = yearsOf(g.years);
  return {
    gen_id: g.gen_id, make: g.make, model: g.model, generation: g.generation,
    year_from: from, year_to: to,
    badges: g.platform_badges || null,
    wheelbases_mm: g.wheelbase_variants_mm.split(';').map(Number).filter(n => !Number.isNaN(n)),
    track_front_mm: num(g.track_front_mm),
    track_rear_mm: /^\d+$/.test(g.track_rear_mm) ? Number(g.track_rear_mm) : null,
    track_confidence: g.track_confidence,
    camper_relevance: g.camper_relevance,
    notes: g.notes,
  };
});

// Preset gen_ids must exist and have confirmed track figures.
for (const p of setupPresets) {
  const g = genRows.find(x => x.gen_id === p.gen_id);
  if (!g) throw new Error(`preset ${p.id}: unknown gen_id ${p.gen_id}`);
  if (g.track_front_mm == null || g.track_rear_mm == null || g.track_confidence === 'tbc')
    throw new Error(`preset ${p.id}: generation ${p.gen_id} lacks confirmed track data`);
}
// Transit Custom preset: most used campers are gen 1, but its track is TBC — fall back to gen 2 figures.
// (Same rationale as T5->T6: nearest confirmed sibling + ESTIMATED tag. Revisit when gen-1 track lands.)

const chassisRows = chassis.map(c => ({
  chassis_id: c.chassis_id, chassis_type: c.chassis_type, fits_platforms: c.fits_platforms,
  wheelbase_range_mm: c.wheelbase_range_mm, front_track_mm: num(c.front_track_mm),
  rear_track_mm_min: c.rear_track_mm.includes('-') ? Number(c.rear_track_mm.split('-')[0]) : num(c.rear_track_mm.replace('-est', '')),
  rear_track_mm_max: c.rear_track_mm.includes('-') ? Number(String(c.rear_track_mm.split('-')[1]).replace(/[^\d]/g, '')) || null : num(c.rear_track_mm.replace('-est', '')),
  rear_track_confidence: c.rear_track_confidence, axle_config: c.axle_config, notes: c.notes,
}));

// Typical rear track used when the user picks "Widened (AL-KO)" but leaves the exact field blank:
// midpoint of the AL-KO Sevel range, rounded — 1920mm (matches the design copy).
const ALKO_TYPICAL_REAR_TRACK_MM = 1920;

const q = s => (s == null ? 'null' : `'${String(s).replace(/'/g, "''")}'`);
const arr = a => `'{${a.join(',')}}'`;

let sql = `-- GENERATED by scripts/gen-seed.js — do not hand-edit. Source: Data/*.csv
insert into vehicle_generations (gen_id, make, model, generation, year_from, year_to, badges, wheelbases_mm, track_front_mm, track_rear_mm, track_confidence, camper_relevance, notes) values
${genRows.map(g => `(${q(g.gen_id)}, ${q(g.make)}, ${q(g.model)}, ${q(g.generation)}, ${g.year_from ?? 'null'}, ${g.year_to ?? 'null'}, ${q(g.badges)}, ${arr(g.wheelbases_mm)}, ${g.track_front_mm ?? 'null'}, ${g.track_rear_mm ?? 'null'}, ${q(g.track_confidence)}, ${q(g.camper_relevance)}, ${q(g.notes)})`).join(',\n')}
on conflict (gen_id) do update set make=excluded.make, model=excluded.model, generation=excluded.generation, year_from=excluded.year_from, year_to=excluded.year_to, badges=excluded.badges, wheelbases_mm=excluded.wheelbases_mm, track_front_mm=excluded.track_front_mm, track_rear_mm=excluded.track_rear_mm, track_confidence=excluded.track_confidence, camper_relevance=excluded.camper_relevance, notes=excluded.notes;

insert into chassis_types (chassis_id, chassis_type, fits_platforms, wheelbase_range_mm, front_track_mm, rear_track_mm_min, rear_track_mm_max, rear_track_confidence, axle_config, notes) values
${chassisRows.map(c => `(${q(c.chassis_id)}, ${q(c.chassis_type)}, ${q(c.fits_platforms)}, ${q(c.wheelbase_range_mm)}, ${c.front_track_mm ?? 'null'}, ${c.rear_track_mm_min ?? 'null'}, ${c.rear_track_mm_max ?? 'null'}, ${q(c.rear_track_confidence)}, ${q(c.axle_config)}, ${q(c.notes)})`).join(',\n')}
on conflict (chassis_id) do update set chassis_type=excluded.chassis_type, fits_platforms=excluded.fits_platforms, wheelbase_range_mm=excluded.wheelbase_range_mm, front_track_mm=excluded.front_track_mm, rear_track_mm_min=excluded.rear_track_mm_min, rear_track_mm_max=excluded.rear_track_mm_max, rear_track_confidence=excluded.rear_track_confidence, axle_config=excluded.axle_config, notes=excluded.notes;

insert into ramp_profiles (profile_id, name, steps_mm, pro) values
${rampProfiles.map(r => `(${q(r.id)}, ${q(r.name)}, ${arr(r.steps_mm)}, ${r.pro})`).join(',\n')}
on conflict (profile_id) do update set name=excluded.name, steps_mm=excluded.steps_mm, pro=excluded.pro;
`;

const json = {
  generatedFrom: 'Data/van_dimensions_levelspot_v2.csv + Data/coachbuilt_chassis_v1.csv via scripts/gen-seed.js',
  alkoTypicalRearTrackMM: ALKO_TYPICAL_REAR_TRACK_MM,
  setupPresets, generations: genRows, chassisTypes: chassisRows, rampProfiles,
};

fs.mkdirSync(path.join(ROOT, 'supabase', 'migrations'), { recursive: true });
fs.mkdirSync(path.join(ROOT, 'LevelSpot', 'Resources'), { recursive: true });
fs.writeFileSync(path.join(ROOT, 'supabase', 'migrations', '002_seed_reference.sql'), sql);
fs.writeFileSync(path.join(ROOT, 'LevelSpot', 'Resources', 'vehicle_reference.json'), JSON.stringify(json, null, 2));
console.log(`OK: ${genRows.length} generations, ${chassisRows.length} chassis types, ${rampProfiles.length} ramp profiles`);
console.log('Wrote supabase/migrations/002_seed_reference.sql and LevelSpot/Resources/vehicle_reference.json');
