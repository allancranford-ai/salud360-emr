# Salud360 EMR 🏥
### Full-Stack Electronic Medical Records System

> A production-ready EMR built for Mexican private clinics with cross-border US insurance support, AI-powered clinical notes, and Mexican SAT/CFDI billing compliance.

🔗 **Live Demo:** [salud360emr.netlify.app](https://salud360emr.netlify.app)

---

## 📸 Screenshots

| Dashboard | Clinical Notes (AI) | Billing |
|-----------|-------------------|---------|
| Patient overview, today's appointments, alerts | AI-generated SOAP notes via Claude API | CFDI 4.0 Mexican tax invoicing |

---

## 🛠️ Tech Stack

| Layer | Technology |
|-------|-----------|
| **Frontend** | HTML5, CSS3, Vanilla JavaScript |
| **Database** | PostgreSQL via Supabase |
| **Auth** | Supabase Auth (JWT, Row Level Security) |
| **Backend Logic** | Supabase Edge Functions (Deno/TypeScript) |
| **AI** | Anthropic Claude API (claude-sonnet-4-6) |
| **Billing** | Facturama API — CFDI 4.0 SAT compliance |
| **Storage** | Supabase Storage / Cloudflare R2 (PACS) |
| **Hosting** | Netlify |

---

## ✨ Features

### 🏥 Clinical
- **Patient Records** — Full expediente with auto-generated EMR numbers (EMR-2025-0001)
- **SOAP Clinical Notes** — AI-generated medical notes powered by Claude API
- **Vital Signs** — Auto-calculates BMI, tracks trends over time
- **Diagnoses** — CIE-10 coded diagnoses with status tracking
- **Prescriptions** — Digital prescriptions with auto-generated folios (RX-2025-0001)
- **Lab Results** — Structured lab tracking with normal/high/low/critical flags
- **Dental Odontogram** — Full FDI notation dental chart with treatment planning
- **Diagnostic Imaging (PACS)** — DICOM, JPEG, PNG, PDF support with cloud storage
- **Patient History** — Complete visit history with filters

### 💰 Financial
- **CFDI 4.0 Billing** — Full Mexican SAT tax invoice compliance
- **Insurance Claims** — Mexican (GNP, AXA, Metlife) and US (BCBS, Cigna, Aetna) insurers
- **CPT/CPTM Codes** — Cross-border procedure coding for US insurance
- **Invoice Management** — Auto-generated folios, multiple payment methods

### 🔐 Security & Architecture
- **Multi-clinic isolation** — Row Level Security (RLS) ensures complete data separation
- **Role-based access** — Admin, médico, enfermera, recepción, odontólogo, contabilidad
- **JWT Authentication** — Secure session management via Supabase Auth
- **HIPAA-aligned design** — Audit trails, digital signatures, access controls

### 🌐 Patient Portal
- Online appointment booking
- Prescription access
- Lab results viewing
- WhatsApp/email notifications (Twilio integration ready)

---

## 🗄️ Database Schema

**18 tables** with full relational integrity:

```
clinics                    → Multi-clinic support
user_profiles              → Staff roles per clinic
patients                   → Patient demographics + insurance
appointments               → Scheduling with status tracking
clinical_notes             → SOAP notes with AI metadata
vital_signs                → Auto-calculated IMC trigger
patient_diagnoses          → CIE-10 coded conditions
patient_background         → Personal + family history
prescriptions              → Digital Rx with folios
prescription_items         → Line items per prescription
diagnostic_images          → PACS image metadata
dental_chart               → FDI tooth chart
dental_treatment_plan      → Dental procedures + costs
lab_results                → Lab order tracking
lab_result_items           → Individual test results
invoices                   → CFDI billing records
invoice_items              → Line items per invoice
insurance_claims           → MX + US claim tracking
ai_note_log                → AI usage + cost tracking
portal_appointment_requests→ Patient portal bookings
clinic_schedules           → Doctor availability
```

### Key Database Features
- **Auto-generated folios** via PostgreSQL triggers (EMR, RX, FAC, CLM)
- **Auto-calculated BMI** on vital signs insert/update
- **Row Level Security** on all 18 tables using `my_clinic_id()` helper
- **Accent-insensitive search** via `unaccent` extension
- **UUID primary keys** throughout

---

## 🤖 AI Integration

Clinical notes are generated via **Anthropic Claude API** deployed as a Supabase Edge Function:

```typescript
// Supabase Edge Function: generate-clinical-note
POST /functions/v1/generate-clinical-note
Authorization: Bearer <user_jwt>

{
  "motivo": "Patient presents with...",
  "exploracion": "Physical exam findings...",
  "tipo_nota": "SOAP — Nota de evolución"
}
```

**AI generates:**
- Full SOAP structured notes
- CIE-10 diagnosis suggestions
- Treatment plan recommendations
- Discharge summaries
- Referral letters

All AI usage is logged in `ai_note_log` for cost tracking and auditing.

---

## 🚀 Getting Started

### Prerequisites
- [Supabase](https://supabase.com) account (free tier works)
- [Anthropic API key](https://console.anthropic.com) for AI notes
- [Facturama](https://facturama.mx) account for CFDI billing (sandbox available)
- [Netlify](https://netlify.com) account for hosting (free tier works)

### Setup

**1. Database**
```sql
-- Run in Supabase SQL Editor in order:
01_schema.sql        -- Core tables, triggers, RLS
02_auth_setup.sql    -- Multi-clinic auth policies
03_billing_cfdi.sql  -- Billing and insurance tables
```

**2. AI Edge Function**
```bash
# In Supabase → Edge Functions → New Function
# Name: generate-clinical-note
# Paste contents of 04_ai_edge_function.ts
# Add secret: ANTHROPIC_API_KEY
```

**3. Frontend**
```javascript
// In index.html, update:
const SUPABASE_URL = 'https://YOUR-PROJECT.supabase.co'
const SUPABASE_KEY = 'YOUR-PUBLISHABLE-KEY'
```

**4. Deploy**
```
Drag index.html to app.netlify.com/drop
```

---

## 💰 Running Costs

| Service | Plan | Cost |
|---------|------|------|
| Supabase | Free | $0/mo |
| Netlify | Free | $0/mo |
| Anthropic Claude | Pay per use | ~$5–20 USD/mo |
| Facturama CFDI | Per stamp | ~$0.10/invoice |
| Cloudflare R2 | Pay per use | ~$5 USD/TB |
| **Total** | | **~$200–500 MXN/mo** |

---

## 📁 Project Structure

```
salud360-emr/
├── index.html              # Full frontend (single-file app)
├── 01_schema.sql           # Database schema + RLS
├── 02_auth_setup.sql       # Auth policies + patient portal
├── 03_billing_cfdi.sql     # Billing + insurance schema
├── 04_ai_edge_function.ts  # Claude AI edge function
└── README.md
```

---

## 🗺️ Roadmap

- [ ] WhatsApp Business API reminders (Twilio)
- [ ] Automatic CFDI generation on payment
- [ ] React Native mobile app
- [ ] Telemedicine (Daily.co / Whereby)
- [ ] HL7 FHIR compliance
- [ ] Multi-language support (EN/ES)

---

## 👨‍💻 Author

**Allan Cranford**
- Designed for clinics in San Luis Río Colorado, Sonora and the US-Mexico border region

---

## 📄 License

MIT License — feel free to use this as a starting point for your own clinic management system.

---

*Built with ❤️ for the Mexican healthcare system*
