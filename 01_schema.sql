-- ============================================================
-- SALUD360 EMR — DATABASE SCHEMA
-- Section 1 of 4: Core Tables + Row Level Security
-- Run this in: Supabase → SQL Editor → New Query
-- ============================================================

-- ────────────────────────────────────────────
-- STEP 1: ENABLE EXTENSIONS
-- ────────────────────────────────────────────
create extension if not exists "uuid-ossp";
create extension if not exists "unaccent";  -- for accent-insensitive patient search

-- ────────────────────────────────────────────
-- STEP 2: CLINICS TABLE
-- One row per physical location / branch
-- ────────────────────────────────────────────
create table clinics (
  id                uuid primary key default uuid_generate_v4(),
  name              text not null,                        -- "Clínica García Medicina General"
  short_name        text,                                 -- "Clínica García" (for UI)
  clinic_type       text default 'general',               -- 'general' | 'dental' | 'especialidad'
  city              text,
  state             text,
  address           text,
  phone             text,
  email             text,
  rfc               text,                                 -- RFC de la razón social (para CFDI)
  razon_social      text,                                 -- Razón social completa
  cedula_director   text,                                 -- Cédula del médico director
  logo_url          text,
  accent_color      text default '#1e6b45',              -- Brand color per clinic
  timezone          text default 'America/Hermosillo',   -- Important for appointments
  currency          text default 'MXN',
  active            boolean default true,
  created_at        timestamptz default now(),
  updated_at        timestamptz default now()
);

-- ────────────────────────────────────────────
-- STEP 3: USER PROFILES
-- Extends Supabase auth.users with clinic role
-- ────────────────────────────────────────────
create table user_profiles (
  id                uuid primary key references auth.users(id) on delete cascade,
  clinic_id         uuid references clinics(id) on delete cascade,
  full_name         text not null,
  role              text not null default 'recepcion',
  -- Roles: 'admin' | 'medico' | 'enfermera' | 'odontologo' | 'recepcion' | 'farmacia' | 'contabilidad'
  especialidad      text,                                 -- "Medicina General", "Cardiología", etc.
  cedula_profesional text,
  phone             text,
  avatar_url        text,
  active            boolean default true,
  created_at        timestamptz default now(),
  updated_at        timestamptz default now()
);

-- ────────────────────────────────────────────
-- STEP 4: PATIENTS
-- ────────────────────────────────────────────
create table patients (
  id                uuid primary key default uuid_generate_v4(),
  clinic_id         uuid not null references clinics(id) on delete cascade,
  expediente_num    text,                                 -- Auto-generated: EMR-2025-0001
  nombre            text not null,
  apellido_paterno  text not null,
  apellido_materno  text,
  fecha_nacimiento  date,
  sexo              text,                                 -- 'M' | 'F' | 'O'
  curp              text,
  rfc               text,
  telefono          text,
  telefono_emergencia text,
  email             text,
  direccion         text,
  ciudad            text,
  estado_republica  text,
  codigo_postal     text,
  -- Insurance
  seguro_principal  text,                                 -- 'GNP' | 'AXA' | 'IMSS' | 'BCBS' etc.
  num_poliza        text,
  seguro_secundario text,                                 -- e.g. US insurance for border patients
  num_poliza_sec    text,
  -- Medical flags
  tipo_sangre       text,                                 -- 'O+' | 'A-' etc.
  alergias          text[],                              -- Array: ['Penicilina','NSAIDs']
  discapacidad      text,
  nota_importante   text,                                 -- Red flag note shown on all screens
  -- Portal access
  portal_email      text,                                 -- For patient portal login
  portal_active     boolean default false,
  -- Meta
  created_by        uuid references user_profiles(id),
  created_at        timestamptz default now(),
  updated_at        timestamptz default now()
);

-- Auto-generate expediente number
create or replace function generate_expediente_num()
returns trigger as $$
declare
  year_part text;
  seq_num   int;
  clinic_prefix text;
begin
  year_part := to_char(now(), 'YYYY');
  select count(*) + 1 into seq_num
    from patients
   where clinic_id = NEW.clinic_id
     and extract(year from created_at) = extract(year from now());
  NEW.expediente_num := 'EMR-' || year_part || '-' || lpad(seq_num::text, 4, '0');
  return NEW;
end;
$$ language plpgsql;

create trigger set_expediente_num
  before insert on patients
  for each row
  when (NEW.expediente_num is null)
  execute function generate_expediente_num();

-- ────────────────────────────────────────────
-- STEP 5: APPOINTMENTS
-- ────────────────────────────────────────────
create table appointments (
  id                uuid primary key default uuid_generate_v4(),
  clinic_id         uuid not null references clinics(id) on delete cascade,
  patient_id        uuid not null references patients(id) on delete cascade,
  doctor_id         uuid not null references user_profiles(id),
  fecha_hora        timestamptz not null,
  duracion_min      int default 30,
  tipo_cita         text default 'consulta_general',
  -- Types: 'consulta_general' | 'control' | 'urgencia' | 'dental' | 'procedimiento' | 'cirugia'
  motivo            text,
  estado            text default 'pendiente',
  -- States: 'pendiente' | 'confirmada' | 'en_curso' | 'completada' | 'cancelada' | 'no_asistio'
  cancelacion_motivo text,
  -- Portal booking
  booked_via_portal boolean default false,
  confirmacion_enviada boolean default false,
  recordatorio_enviado boolean default false,
  -- Notes
  notas_previas     text,
  created_by        uuid references user_profiles(id),
  created_at        timestamptz default now(),
  updated_at        timestamptz default now()
);

-- ────────────────────────────────────────────
-- STEP 6: CLINICAL NOTES (SOAP)
-- ────────────────────────────────────────────
create table clinical_notes (
  id                uuid primary key default uuid_generate_v4(),
  clinic_id         uuid not null references clinics(id) on delete cascade,
  patient_id        uuid not null references patients(id) on delete cascade,
  appointment_id    uuid references appointments(id),
  doctor_id         uuid not null references user_profiles(id),
  fecha_nota        timestamptz default now(),
  tipo_nota         text default 'soap',
  -- Types: 'soap' | 'ingreso' | 'urgencias' | 'dental' | 'alta' | 'interconsulta'
  -- SOAP fields
  subjetivo         text,
  objetivo          text,
  analisis          text,
  plan              text,
  -- Full note (for AI-generated or free-form)
  nota_completa     text,
  -- AI metadata
  generada_con_ia   boolean default false,
  ia_modelo         text,                                -- 'claude-sonnet-4-6'
  ia_prompt_version text,
  -- Diagnoses (CIE-10)
  diagnosticos      jsonb default '[]',
  -- Example: [{"codigo":"E11.9","descripcion":"Diabetes mellitus tipo 2","tipo":"principal"}]
  -- Signature
  firmada           boolean default false,
  fecha_firma       timestamptz,
  firma_cedula      text,
  -- Status
  estado            text default 'borrador',            -- 'borrador' | 'final' | 'firmada'
  created_at        timestamptz default now(),
  updated_at        timestamptz default now()
);

-- ────────────────────────────────────────────
-- STEP 7: VITAL SIGNS
-- ────────────────────────────────────────────
create table vital_signs (
  id                uuid primary key default uuid_generate_v4(),
  clinic_id         uuid not null references clinics(id) on delete cascade,
  patient_id        uuid not null references patients(id) on delete cascade,
  appointment_id    uuid references appointments(id),
  taken_by          uuid references user_profiles(id),
  fecha_hora        timestamptz default now(),
  -- Vitals
  ta_sistolica      numeric(5,1),                       -- mmHg
  ta_diastolica     numeric(5,1),                       -- mmHg
  frecuencia_cardiaca int,                              -- bpm
  frecuencia_respiratoria int,                          -- rpm
  temperatura       numeric(4,1),                       -- °C
  saturacion_o2     numeric(4,1),                       -- %
  glucemia_capilar  numeric(6,1),                       -- mg/dL
  peso_kg           numeric(5,2),
  talla_cm          numeric(5,1),
  imc               numeric(4,1),                       -- Auto-calculated
  perimetro_abdominal numeric(5,1),                    -- cm
  notas             text,
  created_at        timestamptz default now()
);

-- Auto-calculate IMC
create or replace function calculate_imc()
returns trigger as $$
begin
  if NEW.peso_kg is not null and NEW.talla_cm is not null and NEW.talla_cm > 0 then
    NEW.imc := round((NEW.peso_kg / power(NEW.talla_cm / 100.0, 2))::numeric, 1);
  end if;
  return NEW;
end;
$$ language plpgsql;

create trigger calc_imc
  before insert or update on vital_signs
  for each row execute function calculate_imc();

-- ────────────────────────────────────────────
-- STEP 8: DIAGNOSES / ANTECEDENTES
-- ────────────────────────────────────────────
create table patient_diagnoses (
  id                uuid primary key default uuid_generate_v4(),
  clinic_id         uuid not null references clinics(id),
  patient_id        uuid not null references patients(id) on delete cascade,
  codigo_cie10      text not null,
  descripcion       text not null,
  tipo              text default 'cronico',             -- 'cronico' | 'agudo' | 'antecedente'
  estado            text default 'activo',              -- 'activo' | 'remision' | 'resuelto'
  fecha_diagnostico date,
  notas             text,
  created_by        uuid references user_profiles(id),
  created_at        timestamptz default now()
);

create table patient_background (
  id                uuid primary key default uuid_generate_v4(),
  clinic_id         uuid not null references clinics(id),
  patient_id        uuid not null references patients(id) on delete cascade,
  -- Personal
  padecimientos_previos text,
  cirugias          text,
  hospitalizaciones text,
  tabaquismo        text,                               -- 'no' | 'ex' | 'activo'
  alcoholismo       text,                               -- 'no' | 'ocasional' | 'frecuente'
  drogas            text,
  actividad_fisica  text,
  dieta             text,
  -- Family
  padre             text,
  madre             text,
  hermanos          text,
  abuelos           text,
  otros_familiares  text,
  -- Gyneco-obstetric (if applicable)
  menarca           text,
  fum               date,
  gestas            int,
  partos            int,
  cesareas          int,
  abortos           int,
  -- Updated
  updated_by        uuid references user_profiles(id),
  updated_at        timestamptz default now()
);

-- ────────────────────────────────────────────
-- STEP 9: PRESCRIPTIONS
-- ────────────────────────────────────────────
create table prescriptions (
  id                uuid primary key default uuid_generate_v4(),
  clinic_id         uuid not null references clinics(id) on delete cascade,
  patient_id        uuid not null references patients(id) on delete cascade,
  appointment_id    uuid references appointments(id),
  doctor_id         uuid not null references user_profiles(id),
  folio_receta      text,                              -- Auto: RX-2025-0001
  fecha_emision     date default current_date,
  fecha_vencimiento date,
  estado            text default 'activa',             -- 'activa' | 'vencida' | 'cancelada'
  indicaciones_generales text,
  -- Digital send
  enviada_whatsapp  boolean default false,
  enviada_email     boolean default false,
  impresa           boolean default false,
  created_at        timestamptz default now()
);

create table prescription_items (
  id                uuid primary key default uuid_generate_v4(),
  prescription_id   uuid not null references prescriptions(id) on delete cascade,
  clinic_id         uuid not null references clinics(id),
  medicamento       text not null,
  presentacion      text,                              -- "Tabletas 850mg"
  cantidad          text,
  posologia         text,                              -- "1 tableta cada 12 horas"
  duracion_dias     int,
  via_administracion text default 'oral',
  con_alimentos     boolean default false,
  indicaciones      text,
  sort_order        int default 0
);

-- Auto-generate prescription folio
create or replace function generate_rx_folio()
returns trigger as $$
declare
  year_part text;
  seq_num   int;
begin
  year_part := to_char(now(), 'YYYY');
  select count(*) + 1 into seq_num
    from prescriptions
   where clinic_id = NEW.clinic_id
     and extract(year from created_at) = extract(year from now());
  NEW.folio_receta := 'RX-' || year_part || '-' || lpad(seq_num::text, 4, '0');
  return NEW;
end;
$$ language plpgsql;

create trigger set_rx_folio
  before insert on prescriptions
  for each row
  when (NEW.folio_receta is null)
  execute function generate_rx_folio();

-- ────────────────────────────────────────────
-- STEP 10: DIAGNOSTIC IMAGES (PACS)
-- ────────────────────────────────────────────
create table diagnostic_images (
  id                uuid primary key default uuid_generate_v4(),
  clinic_id         uuid not null references clinics(id) on delete cascade,
  patient_id        uuid not null references patients(id) on delete cascade,
  appointment_id    uuid references appointments(id),
  uploaded_by       uuid references user_profiles(id),
  tipo_estudio      text not null,
  -- Types: 'radiografia' | 'tomografia' | 'resonancia' | 'ultrasonido' | 'dental_periapical' | 'dental_panoramica'
  region_anatomica  text,
  fecha_estudio     date default current_date,
  file_url          text not null,                     -- Cloudflare R2 / Supabase Storage URL
  file_size_kb      int,
  formato           text,                              -- 'DICOM' | 'JPEG' | 'PNG' | 'PDF'
  reporte           text,                              -- Radiologist interpretation
  reportado_por     text,
  created_at        timestamptz default now()
);

-- ────────────────────────────────────────────
-- STEP 11: DENTAL CHART
-- ────────────────────────────────────────────
create table dental_chart (
  id                uuid primary key default uuid_generate_v4(),
  clinic_id         uuid not null references clinics(id),
  patient_id        uuid not null references patients(id) on delete cascade,
  numero_diente     int not null,                      -- 11-18, 21-28, 31-38, 41-48 (FDI notation)
  estado            text default 'sano',
  -- States: 'sano' | 'caries' | 'obturado' | 'extraccion_indicada' | 'extraido' | 'corona' | 'protesis' | 'implante'
  superficies       text[],                            -- ['mesial','oclusal','distal','vestibular','palatino']
  material          text,                              -- 'amalgama' | 'resina' | 'porcelana' etc.
  notas             text,
  updated_by        uuid references user_profiles(id),
  updated_at        timestamptz default now(),
  unique(patient_id, numero_diente)
);

create table dental_treatment_plan (
  id                uuid primary key default uuid_generate_v4(),
  clinic_id         uuid not null references clinics(id),
  patient_id        uuid not null references patients(id),
  numero_diente     int,
  procedimiento     text not null,
  costo             numeric(10,2),
  estado            text default 'pendiente',          -- 'pendiente' | 'en_proceso' | 'completado' | 'cancelado'
  fecha_completado  date,
  notas             text,
  created_by        uuid references user_profiles(id),
  created_at        timestamptz default now()
);

-- ────────────────────────────────────────────
-- STEP 12: LABORATORY RESULTS
-- ────────────────────────────────────────────
create table lab_results (
  id                uuid primary key default uuid_generate_v4(),
  clinic_id         uuid not null references clinics(id) on delete cascade,
  patient_id        uuid not null references patients(id) on delete cascade,
  appointment_id    uuid references appointments(id),
  solicitado_por    uuid references user_profiles(id),
  fecha_solicitud   date default current_date,
  fecha_resultado   date,
  laboratorio       text,
  estado            text default 'solicitado',         -- 'solicitado' | 'recibido' | 'revisado'
  file_url          text,                              -- PDF of full results
  created_at        timestamptz default now()
);

create table lab_result_items (
  id                uuid primary key default uuid_generate_v4(),
  lab_result_id     uuid not null references lab_results(id) on delete cascade,
  clinic_id         uuid not null references clinics(id),
  estudio           text not null,                     -- "Glucosa en ayunas"
  resultado         text,                              -- "126"
  unidad            text,                              -- "mg/dL"
  referencia_min    numeric,
  referencia_max    numeric,
  estado_resultado  text,                              -- 'normal' | 'alto' | 'bajo' | 'critico'
  sort_order        int default 0
);

-- ────────────────────────────────────────────
-- STEP 13: BILLING / INVOICES
-- ────────────────────────────────────────────
create table invoices (
  id                uuid primary key default uuid_generate_v4(),
  clinic_id         uuid not null references clinics(id) on delete cascade,
  patient_id        uuid not null references patients(id),
  appointment_id    uuid references appointments(id),
  folio             text,                              -- Auto: FAC-2025-0001
  fecha_emision     timestamptz default now(),
  estado            text default 'pendiente',          -- 'pendiente' | 'pagada' | 'cancelada' | 'parcial'
  metodo_pago       text,                              -- 'efectivo' | 'tarjeta' | 'transferencia' | 'seguro'
  -- Insurance
  es_seguro         boolean default false,
  aseguradora       text,
  num_autorizacion  text,
  -- CFDI fields (Mexican tax invoice)
  cfdi_uuid         text,                              -- UUID del timbre fiscal SAT
  cfdi_xml_url      text,
  cfdi_pdf_url      text,
  cfdi_status       text default 'no_emitido',        -- 'no_emitido' | 'emitido' | 'cancelado'
  rfc_receptor      text,
  razon_social_receptor text,
  uso_cfdi          text default 'P01',               -- SAT use code
  -- Amounts
  subtotal          numeric(12,2) default 0,
  descuento         numeric(12,2) default 0,
  iva               numeric(12,2) default 0,
  total             numeric(12,2) default 0,
  moneda            text default 'MXN',
  tipo_cambio       numeric(10,4) default 1,          -- For USD invoices (border clinics)
  notas             text,
  created_by        uuid references user_profiles(id),
  created_at        timestamptz default now(),
  updated_at        timestamptz default now()
);

create table invoice_items (
  id                uuid primary key default uuid_generate_v4(),
  invoice_id        uuid not null references invoices(id) on delete cascade,
  clinic_id         uuid not null references clinics(id),
  descripcion       text not null,
  clave_sat         text,                              -- SAT product/service key
  cantidad          numeric(10,3) default 1,
  precio_unitario   numeric(10,2) not null,
  descuento         numeric(10,2) default 0,
  importe           numeric(10,2) not null,
  iva_aplicable     boolean default false,
  sort_order        int default 0
);

-- Auto-generate invoice folio
create or replace function generate_invoice_folio()
returns trigger as $$
declare
  year_part text;
  seq_num   int;
begin
  year_part := to_char(now(), 'YYYY');
  select count(*) + 1 into seq_num
    from invoices
   where clinic_id = NEW.clinic_id
     and extract(year from created_at) = extract(year from now());
  NEW.folio := 'FAC-' || year_part || '-' || lpad(seq_num::text, 4, '0');
  return NEW;
end;
$$ language plpgsql;

create trigger set_invoice_folio
  before insert on invoices
  for each row
  when (NEW.folio is null)
  execute function generate_invoice_folio();

-- ────────────────────────────────────────────
-- STEP 14: INSURANCE CLAIMS
-- ────────────────────────────────────────────
create table insurance_claims (
  id                uuid primary key default uuid_generate_v4(),
  clinic_id         uuid not null references clinics(id) on delete cascade,
  patient_id        uuid not null references patients(id),
  invoice_id        uuid references invoices(id),
  folio_claim       text,                              -- Auto: CLM-2025-0001
  aseguradora       text not null,
  tipo_seguro       text default 'mexico',             -- 'mexico' | 'usa' | 'internacional'
  num_poliza        text,
  num_autorizacion  text,
  -- Diagnosis & procedures
  diagnostico_principal text,                          -- CIE-10 code
  diagnostico_desc  text,
  codigos_cpt       text[],                            -- CPT codes for US insurance
  codigos_cptm      text[],                            -- Mexican equivalent
  -- Amounts
  monto_reclamado   numeric(12,2),
  moneda_reclamo    text default 'MXN',
  monto_aprobado    numeric(12,2),
  monto_deducible   numeric(12,2),
  monto_coaseguro   numeric(12,2),
  -- Status
  estado            text default 'en_proceso',
  -- States: 'en_proceso' | 'en_revision' | 'aprobado' | 'rechazado' | 'apelacion'
  fecha_envio       date default current_date,
  fecha_respuesta   date,
  motivo_rechazo    text,
  documentos_urls   text[],                            -- Array of supporting doc URLs
  notas             text,
  created_by        uuid references user_profiles(id),
  created_at        timestamptz default now(),
  updated_at        timestamptz default now()
);

-- Auto-generate claim folio
create or replace function generate_claim_folio()
returns trigger as $$
declare seq_num int;
begin
  select count(*) + 1 into seq_num from insurance_claims where clinic_id = NEW.clinic_id;
  NEW.folio_claim := 'CLM-' || to_char(now(), 'YYYY') || '-' || lpad(seq_num::text, 4, '0');
  return NEW;
end;
$$ language plpgsql;

create trigger set_claim_folio
  before insert on insurance_claims
  for each row
  when (NEW.folio_claim is null)
  execute function generate_claim_folio();

-- ────────────────────────────────────────────
-- STEP 15: AI NOTE LOG
-- Track all AI-generated content per clinic
-- ────────────────────────────────────────────
create table ai_note_log (
  id                uuid primary key default uuid_generate_v4(),
  clinic_id         uuid not null references clinics(id),
  patient_id        uuid references patients(id),
  doctor_id         uuid references user_profiles(id),
  note_id           uuid references clinical_notes(id),
  tipo_nota         text,
  prompt_tokens     int,
  completion_tokens int,
  total_tokens      int,
  modelo            text default 'claude-sonnet-4-6',
  costo_usd         numeric(8,6),                     -- Cost tracking
  latencia_ms       int,
  created_at        timestamptz default now()
);

-- ────────────────────────────────────────────
-- STEP 16: PATIENT PORTAL APPOINTMENTS
-- Requests submitted by patients via portal
-- ────────────────────────────────────────────
create table portal_appointment_requests (
  id                uuid primary key default uuid_generate_v4(),
  clinic_id         uuid not null references clinics(id),
  patient_id        uuid not null references patients(id),
  fecha_preferida   date,
  hora_preferida    time,
  tipo_cita         text,
  motivo            text,
  estado            text default 'pendiente',          -- 'pendiente' | 'confirmada' | 'rechazada'
  appointment_id    uuid references appointments(id),  -- Set when confirmed by staff
  respuesta_staff   text,
  created_at        timestamptz default now()
);

-- ────────────────────────────────────────────
-- STEP 17: CLINIC SCHEDULE / HORARIOS
-- ────────────────────────────────────────────
create table clinic_schedules (
  id                uuid primary key default uuid_generate_v4(),
  clinic_id         uuid not null references clinics(id),
  doctor_id         uuid not null references user_profiles(id),
  dia_semana        int not null,                      -- 0=Sunday...6=Saturday
  hora_inicio       time not null,
  hora_fin          time not null,
  duracion_slot_min int default 30,
  activo            boolean default true,
  unique(clinic_id, doctor_id, dia_semana)
);

-- ────────────────────────────────────────────
-- STEP 18: INDEXES (performance)
-- ────────────────────────────────────────────
create index idx_patients_clinic       on patients(clinic_id);
create index idx_patients_nombre       on patients(clinic_id, apellido_paterno, nombre);
create index idx_patients_curp         on patients(curp);
create index idx_appointments_clinic   on appointments(clinic_id);
create index idx_appointments_fecha    on appointments(clinic_id, fecha_hora);
create index idx_appointments_doctor   on appointments(doctor_id, fecha_hora);
create index idx_appointments_patient  on appointments(patient_id);
create index idx_notes_patient         on clinical_notes(patient_id);
create index idx_notes_clinic          on clinical_notes(clinic_id, fecha_nota desc);
create index idx_vitals_patient        on vital_signs(patient_id, fecha_hora desc);
create index idx_invoices_clinic       on invoices(clinic_id, fecha_emision desc);
create index idx_invoices_patient      on invoices(patient_id);
create index idx_claims_clinic         on insurance_claims(clinic_id, created_at desc);
create index idx_images_patient        on diagnostic_images(patient_id, fecha_estudio desc);

-- ────────────────────────────────────────────
-- STEP 19: ROW LEVEL SECURITY (RLS)
-- This ISOLATES each clinic's data completely
-- ────────────────────────────────────────────

-- Enable RLS on all tables
alter table clinics                     enable row level security;
alter table user_profiles               enable row level security;
alter table patients                    enable row level security;
alter table appointments                enable row level security;
alter table clinical_notes              enable row level security;
alter table vital_signs                 enable row level security;
alter table patient_diagnoses           enable row level security;
alter table patient_background          enable row level security;
alter table prescriptions               enable row level security;
alter table prescription_items          enable row level security;
alter table diagnostic_images           enable row level security;
alter table dental_chart                enable row level security;
alter table dental_treatment_plan       enable row level security;
alter table lab_results                 enable row level security;
alter table lab_result_items            enable row level security;
alter table invoices                    enable row level security;
alter table invoice_items               enable row level security;
alter table insurance_claims            enable row level security;
alter table ai_note_log                 enable row level security;
alter table portal_appointment_requests enable row level security;
alter table clinic_schedules            enable row level security;

-- Helper function: get current user's clinic_id
create or replace function my_clinic_id()
returns uuid as $$
  select clinic_id from user_profiles where id = auth.uid()
$$ language sql security definer stable;

-- Helper function: get current user's role
create or replace function my_role()
returns text as $$
  select role from user_profiles where id = auth.uid()
$$ language sql security definer stable;

-- RLS POLICIES: Users only see their own clinic's data
-- Pattern: (clinic_id = my_clinic_id())

create policy "clinic_isolation" on patients
  using (clinic_id = my_clinic_id());

create policy "clinic_isolation" on appointments
  using (clinic_id = my_clinic_id());

create policy "clinic_isolation" on clinical_notes
  using (clinic_id = my_clinic_id());

create policy "clinic_isolation" on vital_signs
  using (clinic_id = my_clinic_id());

create policy "clinic_isolation" on patient_diagnoses
  using (clinic_id = my_clinic_id());

create policy "clinic_isolation" on patient_background
  using (clinic_id = my_clinic_id());

create policy "clinic_isolation" on prescriptions
  using (clinic_id = my_clinic_id());

create policy "clinic_isolation" on prescription_items
  using (clinic_id = my_clinic_id());

create policy "clinic_isolation" on diagnostic_images
  using (clinic_id = my_clinic_id());

create policy "clinic_isolation" on dental_chart
  using (clinic_id = my_clinic_id());

create policy "clinic_isolation" on dental_treatment_plan
  using (clinic_id = my_clinic_id());

create policy "clinic_isolation" on lab_results
  using (clinic_id = my_clinic_id());

create policy "clinic_isolation" on lab_result_items
  using (clinic_id = my_clinic_id());

create policy "clinic_isolation" on invoices
  using (clinic_id = my_clinic_id());

create policy "clinic_isolation" on invoice_items
  using (clinic_id = my_clinic_id());

create policy "clinic_isolation" on insurance_claims
  using (clinic_id = my_clinic_id());

create policy "clinic_isolation" on ai_note_log
  using (clinic_id = my_clinic_id());

create policy "clinic_isolation" on portal_appointment_requests
  using (clinic_id = my_clinic_id());

create policy "clinic_isolation" on clinic_schedules
  using (clinic_id = my_clinic_id());

-- Users can see their own clinic info
create policy "see_own_clinic" on clinics
  using (id = my_clinic_id());

-- Users see only profiles in their clinic
create policy "clinic_isolation" on user_profiles
  using (clinic_id = my_clinic_id());

-- Allow users to read/update their own profile
create policy "own_profile" on user_profiles
  using (id = auth.uid());

-- ────────────────────────────────────────────
-- STEP 20: SEED DATA — Insert your first clinic
-- EDIT THIS SECTION with your real info
-- ────────────────────────────────────────────

insert into clinics (
  name, short_name, clinic_type,
  city, state, address, phone, email,
  rfc, razon_social,
  accent_color, timezone
) values (
  'Clínica Salud360 — Consultorio Principal',  -- Change this
  'Salud360',                                   -- Change this
  'general',
  'San Luis Río Colorado',                      -- Change this
  'Sonora',
  'Av. Principal 123, Col. Centro',             -- Change this
  '653-123-4567',                               -- Change this
  'info@salud360.mx',                           -- Change this
  'SAL360XXXXXX',                               -- RFC — Change this
  'Salud360 S.A. de C.V.',                      -- Razón social — Change this
  '#1e6b45',                                    -- Brand color
  'America/Hermosillo'
);

-- ✅ SCHEMA COMPLETE
-- Next step: Run 02_auth_setup.sql to configure login
