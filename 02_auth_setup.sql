-- ============================================================
-- SALUD360 EMR — MULTI-CLINIC LOGIN SYSTEM
-- Section 2 of 4: Auth configuration + user management
-- Run this AFTER 01_schema.sql
-- ============================================================

-- ────────────────────────────────────────────
-- STEP 1: AUTO-CREATE USER PROFILE ON SIGNUP
-- When someone signs up, this creates their
-- profile row automatically
-- ────────────────────────────────────────────
create or replace function handle_new_user()
returns trigger as $$
begin
  -- Only create profile if clinic_id is passed in user metadata
  if NEW.raw_user_meta_data->>'clinic_id' is not null then
    insert into public.user_profiles (id, clinic_id, full_name, role)
    values (
      NEW.id,
      (NEW.raw_user_meta_data->>'clinic_id')::uuid,
      coalesce(NEW.raw_user_meta_data->>'full_name', NEW.email),
      coalesce(NEW.raw_user_meta_data->>'role', 'recepcion')
    );
  end if;
  return NEW;
end;
$$ language plpgsql security definer;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- ────────────────────────────────────────────
-- STEP 2: ROLE-BASED ACCESS POLICIES
-- Doctors can create/edit notes
-- Recepcion can only manage appointments
-- Admin can do everything in their clinic
-- ────────────────────────────────────────────

-- Clinical notes: only doctors/nurses can create
create policy "medicos_create_notes" on clinical_notes
  for insert
  with check (
    clinic_id = my_clinic_id()
    and my_role() in ('medico', 'odontologo', 'admin')
  );

create policy "medicos_update_notes" on clinical_notes
  for update
  using (
    clinic_id = my_clinic_id()
    and (doctor_id = auth.uid() or my_role() = 'admin')
    and firmada = false  -- Cannot edit signed notes
  );

-- Prescriptions: only doctors can create
create policy "medicos_create_rx" on prescriptions
  for insert
  with check (
    clinic_id = my_clinic_id()
    and my_role() in ('medico', 'odontologo', 'admin')
  );

-- Invoices: recepcion and admin can create/edit
create policy "staff_manage_invoices" on invoices
  for all
  using (clinic_id = my_clinic_id())
  with check (
    clinic_id = my_clinic_id()
    and my_role() in ('admin', 'recepcion', 'contabilidad')
  );

-- Appointments: all staff can read, recepcion+ can write
create policy "staff_create_appointments" on appointments
  for insert
  with check (
    clinic_id = my_clinic_id()
    and my_role() in ('admin', 'recepcion', 'medico', 'odontologo', 'enfermera')
  );

-- ────────────────────────────────────────────
-- STEP 3: ADMIN USER MANAGEMENT FUNCTIONS
-- ────────────────────────────────────────────

-- Function: invite a new staff member to the clinic
-- Usage: select invite_staff_member('doctor@clinica.mx', 'Dr. Juan García', 'medico');
create or replace function invite_staff_member(
  p_email text,
  p_full_name text,
  p_role text
)
returns text as $$
declare
  v_clinic_id uuid;
begin
  -- Only admins can invite
  if my_role() != 'admin' then
    raise exception 'Solo administradores pueden invitar usuarios';
  end if;

  v_clinic_id := my_clinic_id();

  -- The actual invite is done via Supabase Admin API in the backend
  -- This function validates and returns the metadata to pass
  if p_role not in ('admin','medico','odontologo','enfermera','recepcion','farmacia','contabilidad') then
    raise exception 'Rol inválido: %', p_role;
  end if;

  return json_build_object(
    'clinic_id', v_clinic_id,
    'full_name', p_full_name,
    'role', p_role,
    'email', p_email
  )::text;
end;
$$ language plpgsql security definer;

-- Function: deactivate a staff member
create or replace function deactivate_staff(p_user_id uuid)
returns void as $$
begin
  if my_role() != 'admin' then
    raise exception 'Solo administradores pueden desactivar usuarios';
  end if;
  update user_profiles
     set active = false, updated_at = now()
   where id = p_user_id and clinic_id = my_clinic_id();
end;
$$ language plpgsql security definer;

-- ────────────────────────────────────────────
-- STEP 4: PATIENT PORTAL AUTH
-- Patients get separate limited-access accounts
-- ────────────────────────────────────────────

-- Patient portal sessions table
create table if not exists patient_portal_sessions (
  id            uuid primary key default uuid_generate_v4(),
  clinic_id     uuid not null references clinics(id),
  patient_id    uuid not null references patients(id),
  auth_user_id  uuid references auth.users(id),
  last_active   timestamptz default now(),
  created_at    timestamptz default now()
);

alter table patient_portal_sessions enable row level security;

-- Patients can only see their own session
create policy "own_session" on patient_portal_sessions
  using (auth_user_id = auth.uid());

-- Portal patients have very limited access
-- They can only see THEIR OWN data, nothing else
create policy "portal_patient_read_own" on patients
  for select
  using (
    -- Staff access (already covered above)
    clinic_id = my_clinic_id()
    or
    -- Patient portal access: only their own record
    id = (
      select patient_id from patient_portal_sessions
       where auth_user_id = auth.uid()
         and patient_id = patients.id
       limit 1
    )
  );

create policy "portal_patient_read_appointments" on appointments
  for select
  using (
    clinic_id = my_clinic_id()
    or
    patient_id = (
      select patient_id from patient_portal_sessions
       where auth_user_id = auth.uid() limit 1
    )
  );

create policy "portal_patient_read_prescriptions" on prescriptions
  for select
  using (
    clinic_id = my_clinic_id()
    or
    patient_id = (
      select patient_id from patient_portal_sessions
       where auth_user_id = auth.uid() limit 1
    )
  );

-- Patients can submit appointment requests
create policy "portal_patient_request_appointments" on portal_appointment_requests
  for insert
  with check (
    patient_id = (
      select patient_id from patient_portal_sessions
       where auth_user_id = auth.uid() limit 1
    )
  );

-- ────────────────────────────────────────────
-- STEP 5: USEFUL VIEWS FOR THE APP
-- ────────────────────────────────────────────

-- Today's appointments with patient and doctor info
create or replace view todays_appointments as
select
  a.id,
  a.clinic_id,
  a.fecha_hora,
  a.duracion_min,
  a.tipo_cita,
  a.estado,
  a.motivo,
  a.booked_via_portal,
  -- Patient
  p.id              as patient_id,
  p.expediente_num,
  p.nombre          as patient_nombre,
  p.apellido_paterno,
  p.apellido_materno,
  p.telefono        as patient_telefono,
  p.alergias,
  p.nota_importante,
  -- Doctor
  u.full_name       as doctor_nombre,
  u.especialidad    as doctor_especialidad
from appointments a
join patients     p on p.id = a.patient_id
join user_profiles u on u.id = a.doctor_id
where date(a.fecha_hora at time zone 'America/Hermosillo') = current_date
  and a.clinic_id = my_clinic_id()
order by a.fecha_hora;

-- Patient summary card view
create or replace view patient_summary as
select
  p.id,
  p.clinic_id,
  p.expediente_num,
  p.nombre,
  p.apellido_paterno,
  p.apellido_materno,
  p.nombre || ' ' || p.apellido_paterno || coalesce(' ' || p.apellido_materno, '') as nombre_completo,
  p.fecha_nacimiento,
  date_part('year', age(p.fecha_nacimiento))::int as edad,
  p.sexo,
  p.telefono,
  p.email,
  p.tipo_sangre,
  p.alergias,
  p.seguro_principal,
  p.nota_importante,
  p.portal_active,
  -- Last appointment
  (select fecha_hora from appointments
    where patient_id = p.id
    order by fecha_hora desc limit 1) as ultima_cita,
  -- Active diagnoses count
  (select count(*) from patient_diagnoses
    where patient_id = p.id and estado = 'activo') as num_diagnosticos_activos,
  p.created_at
from patients p
where p.clinic_id = my_clinic_id();

-- ────────────────────────────────────────────
-- STEP 6: SEED — INSERT YOUR FIRST ADMIN USER
-- Run this AFTER creating your account in
-- Supabase Auth (Authentication > Users > Add user)
-- Replace the UUID with your actual auth user ID
-- ────────────────────────────────────────────

-- First: go to Supabase > Authentication > Users > Add user
-- Enter your email + password
-- Copy the UUID shown in the users table
-- Then run:

/*
insert into user_profiles (id, clinic_id, full_name, role, especialidad)
values (
  'PASTE-YOUR-AUTH-USER-UUID-HERE',          -- From Supabase Auth > Users
  (select id from clinics limit 1),          -- Your clinic (from step 1)
  'Dr. Tu Nombre Completo',                  -- Your name
  'admin',                                   -- Role: admin
  'Medicina General'                         -- Your specialty
);
*/

-- ────────────────────────────────────────────
-- STEP 7: SAMPLE STAFF FOR TESTING
-- Run after inserting admin user above
-- (Comment out in production)
-- ────────────────────────────────────────────

/*
-- Test doctor (create auth user first, then insert profile)
insert into user_profiles (id, clinic_id, full_name, role, especialidad, cedula_profesional)
values (
  'DOCTOR-AUTH-UUID',
  (select id from clinics limit 1),
  'Dra. María Ruiz González',
  'odontologo',
  'Odontología General',
  '7654321'
);

-- Test recepcion
insert into user_profiles (id, clinic_id, full_name, role)
values (
  'RECEPCION-AUTH-UUID',
  (select id from clinics limit 1),
  'Laura Martínez Pérez',
  'recepcion'
);
*/

-- ✅ AUTH SETUP COMPLETE
-- Next step: Run 03_billing_cfdi.sql
