-- ============================================================
-- SALUD360 EMR — CFDI BILLING INTEGRATION
-- Section 3 of 4: Mexican + US insurance billing setup
-- Run this AFTER 02_auth_setup.sql
-- ============================================================

-- ────────────────────────────────────────────
-- STEP 1: SAT CATALOG TABLES
-- Products/services and units for CFDI 4.0
-- ────────────────────────────────────────────

-- SAT medical service codes (subset — most common in private clinics)
create table if not exists sat_claves_servicio (
  clave         text primary key,
  descripcion   text not null,
  categoria     text
);

insert into sat_claves_servicio (clave, descripcion, categoria) values
  ('85101500', 'Servicios de consulta médica general',           'Consulta'),
  ('85101501', 'Servicios de consulta médica de especialidad',   'Consulta'),
  ('85101600', 'Servicios odontológicos',                        'Dental'),
  ('85121500', 'Servicios de laboratorio clínico',               'Laboratorio'),
  ('85122000', 'Servicios de radiología e imagen',               'Imagen'),
  ('85131500', 'Servicios de urgencias médicas',                 'Urgencias'),
  ('85141600', 'Servicios de cirugía',                           'Cirugía'),
  ('85111500', 'Servicios de hospitalización',                   'Hospitalización'),
  ('51101500', 'Medicamentos de prescripción',                   'Farmacia'),
  ('85101700', 'Servicios de enfermería',                        'Enfermería'),
  ('85122500', 'Servicios de ultrasonido',                       'Imagen'),
  ('85122600', 'Servicios de tomografía computada',              'Imagen'),
  ('85101800', 'Servicios de rehabilitación física',             'Rehabilitación');

-- SAT units of measure
create table if not exists sat_unidades (
  clave         text primary key,
  descripcion   text not null
);

insert into sat_unidades (clave, descripcion) values
  ('E48', 'Unidad de servicio'),
  ('ACT', 'Actividad'),
  ('H87', 'Pieza'),
  ('KGM', 'Kilogramo'),
  ('LTR', 'Litro');

-- CFDI use codes (Uso CFDI)
create table if not exists sat_uso_cfdi (
  clave         text primary key,
  descripcion   text not null,
  persona_moral boolean default true,
  persona_fisica boolean default true
);

insert into sat_uso_cfdi (clave, descripcion) values
  ('P01', 'Por definir'),
  ('G03', 'Gastos en general'),
  ('D01', 'Honorarios médicos, dentales y gastos hospitalarios'),
  ('D07', 'Primas por seguros de gastos médicos'),
  ('S01', 'Sin efectos fiscales');

-- Payment method codes
create table if not exists sat_metodos_pago (
  clave         text primary key,
  descripcion   text not null
);

insert into sat_metodos_pago (clave, descripcion) values
  ('PUE', 'Pago en una sola exhibición'),
  ('PPD', 'Pago en parcialidades o diferido');

-- Payment form codes (Forma de pago)
create table if not exists sat_formas_pago (
  clave         text primary key,
  descripcion   text not null
);

insert into sat_formas_pago (clave, descripcion) values
  ('01', 'Efectivo'),
  ('02', 'Cheque nominativo'),
  ('03', 'Transferencia electrónica'),
  ('04', 'Tarjeta de crédito'),
  ('28', 'Tarjeta de débito'),
  ('99', 'Por definir');

-- ────────────────────────────────────────────
-- STEP 2: CATALOG OF SERVICES PER CLINIC
-- Each clinic sets their own prices
-- ────────────────────────────────────────────
create table if not exists clinic_services (
  id              uuid primary key default uuid_generate_v4(),
  clinic_id       uuid not null references clinics(id) on delete cascade,
  clave_sat       text references sat_claves_servicio(clave),
  nombre          text not null,
  descripcion     text,
  precio_mxn      numeric(10,2) not null,
  precio_usd      numeric(10,2),              -- For US insurance patients
  unidad_sat      text default 'E48',
  categoria       text,
  activo          boolean default true,
  sort_order      int default 0,
  created_at      timestamptz default now()
);

-- Seed common services (update prices to match your clinic)
-- Run: insert into clinic_services ... after getting clinic id
-- Example services shown below for reference

-- ────────────────────────────────────────────
-- STEP 3: INSURANCE AGREEMENTS PER CLINIC
-- Which insurers does this clinic work with?
-- ────────────────────────────────────────────
create table if not exists clinic_insurance_agreements (
  id              uuid primary key default uuid_generate_v4(),
  clinic_id       uuid not null references clinics(id) on delete cascade,
  aseguradora     text not null,
  tipo            text default 'mexico',       -- 'mexico' | 'usa' | 'internacional'
  num_proveedor   text,                        -- Provider number with insurer
  contacto_nombre text,
  contacto_email  text,
  contacto_tel    text,
  url_portal      text,                        -- Insurer's provider portal
  instrucciones   text,                        -- How to submit claims
  plazo_pago_dias int default 30,
  activo          boolean default true,
  created_at      timestamptz default now()
);

-- ────────────────────────────────────────────
-- STEP 4: FACTURAMA API CONFIG
-- Facturama is a PAC (authorized SAT reseller)
-- that stamps your CFDI invoices digitally
-- Sign up at: facturama.mx
-- ────────────────────────────────────────────

-- Store PAC credentials per clinic (encrypted at rest by Supabase)
create table if not exists clinic_cfdi_config (
  id              uuid primary key default uuid_generate_v4(),
  clinic_id       uuid not null references clinics(id) on delete cascade unique,
  pac_nombre      text default 'Facturama',
  pac_api_url     text default 'https://apisandbox.facturama.mx', -- Change to api.facturama.mx for production
  pac_usuario     text,                        -- Your Facturama username
  pac_password    text,                        -- Store encrypted — use Supabase Vault in production
  -- CSD (Certificado de Sello Digital) — your tax signing certificate
  csd_certificado text,                        -- Base64 encoded .cer file
  csd_llave       text,                        -- Base64 encoded .key file
  csd_password    text,                        -- CSD password
  modo_produccion boolean default false,       -- Set true when ready for real invoices
  serie           text default 'A',            -- Invoice series
  folio_inicio    int default 1,
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);

alter table clinic_cfdi_config enable row level security;
create policy "admin_only_cfdi_config" on clinic_cfdi_config
  using (clinic_id = my_clinic_id() and my_role() = 'admin');

-- ────────────────────────────────────────────
-- STEP 5: BILLING SUMMARY VIEW
-- Easy access for billing dashboard
-- ────────────────────────────────────────────
create or replace view billing_summary_today as
select
  i.id,
  i.clinic_id,
  i.folio,
  i.fecha_emision,
  i.estado,
  i.metodo_pago,
  i.es_seguro,
  i.aseguradora,
  i.total,
  i.moneda,
  i.cfdi_status,
  -- Patient
  p.nombre          as patient_nombre,
  p.apellido_paterno,
  p.expediente_num,
  p.rfc             as patient_rfc,
  -- Created by
  u.full_name       as created_by_nombre
from invoices i
join patients      p on p.id = i.patient_id
join user_profiles u on u.id = i.created_by
where i.clinic_id = my_clinic_id()
  and date(i.fecha_emision) = current_date
order by i.fecha_emision desc;

-- Monthly revenue view
create or replace view monthly_revenue as
select
  clinic_id,
  date_trunc('month', fecha_emision)   as mes,
  count(*)                              as num_facturas,
  sum(case when moneda='MXN' then total else 0 end) as total_mxn,
  sum(case when moneda='USD' then total else 0 end) as total_usd,
  sum(case when es_seguro then total else 0 end)    as total_seguros,
  count(case when cfdi_status='emitido' then 1 end) as cfdi_emitidos
from invoices
where clinic_id = my_clinic_id()
  and estado != 'cancelada'
group by clinic_id, date_trunc('month', fecha_emision)
order by mes desc;

-- ────────────────────────────────────────────
-- STEP 6: US INSURANCE CPT CODE CATALOG
-- Common codes for border clinics (Sonora/BC)
-- ────────────────────────────────────────────
create table if not exists cpt_codes (
  codigo        text primary key,
  descripcion   text not null,
  categoria     text,
  precio_ref_usd numeric(8,2)               -- Reference price in USD
);

insert into cpt_codes (codigo, descripcion, categoria, precio_ref_usd) values
  ('99201', 'Office visit, new patient, straightforward',        'Visita', 75.00),
  ('99202', 'Office visit, new patient, low complexity',         'Visita', 105.00),
  ('99203', 'Office visit, new patient, moderate complexity',    'Visita', 140.00),
  ('99211', 'Office visit, established, minimal',               'Visita', 45.00),
  ('99212', 'Office visit, established, straightforward',       'Visita', 75.00),
  ('99213', 'Office visit, established, low complexity',        'Visita', 105.00),
  ('99214', 'Office visit, established, moderate complexity',   'Visita', 145.00),
  ('99283', 'Emergency dept visit, moderate severity',          'Urgencias', 185.00),
  ('93000', 'Electrocardiogram, routine',                       'Diagnóstico', 65.00),
  ('71046', 'Chest X-ray, 2 views',                             'Imagen', 95.00),
  ('76700', 'Abdominal ultrasound, complete',                   'Imagen', 175.00),
  ('80053', 'Comprehensive metabolic panel',                    'Lab', 55.00),
  ('83036', 'Hemoglobin A1c',                                   'Lab', 45.00),
  ('85025', 'Complete blood count with differential',           'Lab', 35.00),
  ('80061', 'Lipid panel',                                      'Lab', 40.00),
  ('81003', 'Urinalysis',                                       'Lab', 20.00),
  ('D0120', 'Periodic oral exam',                               'Dental', 60.00),
  ('D0150', 'Comprehensive oral evaluation',                    'Dental', 90.00),
  ('D0210', 'Full mouth X-rays',                                'Dental', 130.00),
  ('D1110', 'Prophylaxis, adult cleaning',                      'Dental', 110.00),
  ('D2140', 'Amalgam filling, 1 surface',                       'Dental', 150.00),
  ('D2391', 'Resin filling, 1 surface, posterior',              'Dental', 190.00),
  ('D3310', 'Root canal, anterior',                             'Dental', 750.00),
  ('D3330', 'Root canal, molar',                                'Dental', 1100.00),
  ('D2740', 'Crown, porcelain',                                 'Dental', 1200.00),
  ('D7140', 'Simple extraction',                                'Dental', 200.00);

-- ────────────────────────────────────────────
-- STEP 7: PAYMENT TRACKING
-- Track partial payments, insurance payments
-- ────────────────────────────────────────────
create table if not exists payments (
  id              uuid primary key default uuid_generate_v4(),
  clinic_id       uuid not null references clinics(id),
  invoice_id      uuid not null references invoices(id) on delete cascade,
  fecha_pago      timestamptz default now(),
  monto           numeric(12,2) not null,
  moneda          text default 'MXN',
  forma_pago_sat  text default '01',          -- SAT payment form code
  referencia      text,                        -- Transaction reference / authorization
  banco           text,
  notas           text,
  registered_by   uuid references user_profiles(id),
  created_at      timestamptz default now()
);

alter table payments enable row level security;
create policy "clinic_isolation" on payments
  using (clinic_id = my_clinic_id());

-- Update invoice status when fully paid
create or replace function update_invoice_status()
returns trigger as $$
declare
  v_total      numeric;
  v_pagado     numeric;
begin
  select total into v_total from invoices where id = NEW.invoice_id;
  select coalesce(sum(monto), 0) into v_pagado
    from payments where invoice_id = NEW.invoice_id;

  update invoices set
    estado = case
      when v_pagado >= v_total then 'pagada'
      when v_pagado > 0        then 'parcial'
      else 'pendiente'
    end,
    updated_at = now()
  where id = NEW.invoice_id;

  return NEW;
end;
$$ language plpgsql;

create trigger on_payment_inserted
  after insert on payments
  for each row execute function update_invoice_status();

-- ────────────────────────────────────────────
-- STEP 8: RLS ON NEW TABLES
-- ────────────────────────────────────────────
alter table clinic_services              enable row level security;
alter table clinic_insurance_agreements  enable row level security;
alter table cpt_codes                    enable row level security;

create policy "clinic_isolation" on clinic_services
  using (clinic_id = my_clinic_id());

create policy "clinic_isolation" on clinic_insurance_agreements
  using (clinic_id = my_clinic_id());

-- CPT codes are global reference data — everyone can read
create policy "public_read_cpt" on cpt_codes for select using (true);
create policy "public_read_sat_services" on sat_claves_servicio for select using (true);
create policy "public_read_sat_units" on sat_unidades for select using (true);

-- ────────────────────────────────────────────
-- STEP 9: SEED YOUR CLINIC SERVICES
-- After running above, insert your prices
-- Run this after getting your clinic ID:
-- select id from clinics limit 1;
-- ────────────────────────────────────────────

/*
-- Replace 'YOUR-CLINIC-ID' with the UUID from above
insert into clinic_services (clinic_id, clave_sat, nombre, precio_mxn, precio_usd, categoria) values
  ('YOUR-CLINIC-ID', '85101500', 'Consulta general',           1200.00, 65.00,  'Consulta'),
  ('YOUR-CLINIC-ID', '85101500', 'Consulta de control',         800.00, 45.00,  'Consulta'),
  ('YOUR-CLINIC-ID', '85101501', 'Consulta de especialidad',   1800.00, 95.00,  'Consulta'),
  ('YOUR-CLINIC-ID', '85131500', 'Consulta urgencias',         1500.00, 80.00,  'Urgencias'),
  ('YOUR-CLINIC-ID', '85101600', 'Consulta dental',             900.00, 50.00,  'Dental'),
  ('YOUR-CLINIC-ID', '85101600', 'Limpieza dental',            1200.00, 65.00,  'Dental'),
  ('YOUR-CLINIC-ID', '85101600', 'Resina composite',           1800.00, 95.00,  'Dental'),
  ('YOUR-CLINIC-ID', '85121500', 'Glucosa en ayunas',           180.00, 10.00,  'Laboratorio'),
  ('YOUR-CLINIC-ID', '85121500', 'Biometría hemática',          250.00, 14.00,  'Laboratorio'),
  ('YOUR-CLINIC-ID', '85121500', 'HbA1c',                       380.00, 20.00,  'Laboratorio'),
  ('YOUR-CLINIC-ID', '85121500', 'Panel metabólico completo',   680.00, 37.00,  'Laboratorio'),
  ('YOUR-CLINIC-ID', '85122000', 'Radiografía (2 proyecciones)',580.00, 32.00,  'Imagen'),
  ('YOUR-CLINIC-ID', '85122500', 'Ultrasonido abdominal',      1200.00, 65.00,  'Imagen'),
  ('YOUR-CLINIC-ID', '85141600', 'Electrocardiograma',          500.00, 27.00,  'Diagnóstico');
*/

-- ────────────────────────────────────────────
-- STEP 10: SEED INSURANCE AGREEMENTS
-- ────────────────────────────────────────────
/*
insert into clinic_insurance_agreements
  (clinic_id, aseguradora, tipo, contacto_email, contacto_tel, url_portal) values
  ('YOUR-CLINIC-ID', 'GNP Seguros',              'mexico',        'proveedores@gnp.com.mx', '800-400-9900', 'https://gnp.com.mx/portal-medico'),
  ('YOUR-CLINIC-ID', 'AXA Keralty',              'mexico',        'red@axakeralty.mx',       '800-111-5000', 'https://axakeralty.mx'),
  ('YOUR-CLINIC-ID', 'Metlife México',            'mexico',        'proveedores@metlife.com', '800-633-5433', 'https://metlife.com.mx'),
  ('YOUR-CLINIC-ID', 'Blue Cross Blue Shield',    'usa',           'claims@bcbs.com',         '1-800-676-2583', 'https://bcbs.com/providers'),
  ('YOUR-CLINIC-ID', 'Cigna International',       'usa',           'claims@cigna.com',         '1-800-441-2668', 'https://cigna.com/providers'),
  ('YOUR-CLINIC-ID', 'Aetna International',       'internacional', 'intlclaims@aetna.com',    '1-800-231-7729', 'https://aetna.com'),
  ('YOUR-CLINIC-ID', 'IMSS Subrogado',            'mexico',        'subrogacion@imss.gob.mx', '800-623-2323', 'https://imss.gob.mx');
*/

-- ✅ BILLING SETUP COMPLETE
-- Next step: Run 04_ai_integration.sql
-- Then: Run 05_supabase_edge_functions.js in Supabase Dashboard > Edge Functions
