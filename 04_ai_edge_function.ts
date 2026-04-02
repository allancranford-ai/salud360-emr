// ============================================================
// SALUD360 EMR — CLAUDE AI NOTES INTEGRATION
// Section 4 of 4: Supabase Edge Function
//
// HOW TO DEPLOY THIS:
// 1. Go to Supabase Dashboard > Edge Functions > New Function
// 2. Name it: generate-clinical-note
// 3. Paste this entire file
// 4. Click Deploy
//
// Then go to: Settings > Secrets > Add new secret
// Name: ANTHROPIC_API_KEY
// Value: your API key from console.anthropic.com
// ============================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ─── CORS headers (allow your clinic domain) ───
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",   // In production: set to 'https://yoursite.com'
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// ─── SOAP note system prompt ───
const SYSTEM_PROMPT_SOAP = `Eres un asistente médico especializado en generar notas clínicas SOAP profesionales en español mexicano. 

INSTRUCCIONES:
- Genera notas médicas estructuradas en formato SOAP completo
- Usa terminología médica apropiada en español
- Incluye códigos CIE-10 cuando corresponda en la sección de Análisis
- El tono debe ser profesional y objetivo, como el de un expediente clínico real
- Usa el sistema métrico (°C, kg, cm, mmHg, etc.)
- Incluye recomendaciones clínicas basadas en guías de práctica médica mexicanas (GPC)
- NO inventes datos — solo usa lo que el médico proporciona
- Si la información es insuficiente para un campo SOAP, indícalo brevemente

FORMATO DE SALIDA:
NOTA MÉDICA DE EVOLUCIÓN — SOAP
Fecha: [fecha actual]  |  Médico: [nombre del médico]

SUBJETIVO (S):
[Lo que refiere el paciente: síntomas, duración, intensidad]

OBJETIVO (O):
[Signos vitales y exploración física]

ANÁLISIS (A):
[Diagnóstico con código CIE-10, interpretación clínica]

PLAN (P):
[Tratamiento numerado: medicamentos, estudios, indicaciones, seguimiento]

─────────────────────────────────────────────
[Firma del médico]`;

const SYSTEM_PROMPT_DENTAL = `Eres un asistente para odontólogos especializado en notas clínicas dentales en español mexicano.

Genera notas odontológicas profesionales con:
- Motivo de consulta dental
- Hallazgos clínicos (dientes afectados con numeración FDI)
- Diagnóstico dental
- Plan de tratamiento numerado con costos aproximados
- Indicaciones postoperatorias si aplica
- Próxima cita recomendada

Usa terminología odontológica correcta en español. El tono debe ser el de un expediente clínico dental profesional.`;

const SYSTEM_PROMPT_URGENCIAS = `Eres un asistente para médicos de urgencias. Genera notas de urgencias en español mexicano con:
- Triaje y tiempo de llegada
- Motivo de consulta (inicio, duración, escala de dolor 1-10)
- Signos vitales al ingreso
- Exploración física por sistemas
- Diagnóstico presuntivo con CIE-10
- Tratamiento en urgencias (medicamentos con dosis exactas IV/IM/VO)
- Plan: observación, alta, hospitalización, o referencia
- Condición al egreso

Sé conciso y clínicamente preciso.`;

const SYSTEM_PROMPTS: Record<string, string> = {
  soap:       SYSTEM_PROMPT_SOAP,
  dental:     SYSTEM_PROMPT_DENTAL,
  urgencias:  SYSTEM_PROMPT_URGENCIAS,
  ingreso:    SYSTEM_PROMPT_SOAP,
  alta:       SYSTEM_PROMPT_SOAP,
};

// ─── MAIN FUNCTION ───
serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const startTime = Date.now();

  try {
    // ─── 1. Authenticate the request ───
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: "No autorizado" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Initialize Supabase client with user's JWT
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } }
    );

    // Verify user is authenticated
    const { data: { user }, error: authError } = await supabase.auth.getUser();
    if (authError || !user) {
      return new Response(
        JSON.stringify({ error: "Sesión inválida" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // ─── 2. Get user profile + clinic ───
    const { data: profile, error: profileError } = await supabase
      .from("user_profiles")
      .select("*, clinics(*)")
      .eq("id", user.id)
      .single();

    if (profileError || !profile) {
      return new Response(
        JSON.stringify({ error: "Perfil no encontrado" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Only doctors and admins can generate AI notes
    if (!["medico", "odontologo", "admin"].includes(profile.role)) {
      return new Response(
        JSON.stringify({ error: "Sin permiso para generar notas" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // ─── 3. Parse request body ───
    const body = await req.json();
    const {
      tipo_nota = "soap",       // 'soap' | 'dental' | 'urgencias' | 'ingreso' | 'alta'
      motivo_consulta,          // Required: what patient reports
      exploracion_fisica,       // Optional: physical exam findings
      antecedentes_relevantes,  // Optional: relevant background
      signos_vitales,           // Optional: vitals object
      patient_id,               // Optional: to save note to patient
      appointment_id,           // Optional: link to appointment
    } = body;

    if (!motivo_consulta) {
      return new Response(
        JSON.stringify({ error: "El motivo de consulta es requerido" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // ─── 4. Build the user message ───
    const today = new Date().toLocaleDateString("es-MX", {
      weekday: "long", year: "numeric", month: "long", day: "numeric"
    });

    let userMessage = `Genera una nota médica ${tipo_nota.toUpperCase()} con la siguiente información:

MÉDICO: ${profile.full_name}
ESPECIALIDAD: ${profile.especialidad || "Medicina General"}
FECHA: ${today}
CLÍNICA: ${profile.clinics?.name || "Clínica Privada"}`;

    if (signos_vitales) {
      const sv = signos_vitales;
      userMessage += `\n\nSIGNOS VITALES:
- T/A: ${sv.ta_sistolica || "—"}/${sv.ta_diastolica || "—"} mmHg
- FC: ${sv.frecuencia_cardiaca || "—"} lpm
- Temperatura: ${sv.temperatura || "—"}°C
- SpO₂: ${sv.saturacion_o2 || "—"}%
- Glucemia: ${sv.glucemia_capilar ? sv.glucemia_capilar + " mg/dL" : "—"}
- Peso: ${sv.peso_kg ? sv.peso_kg + " kg" : "—"}  Talla: ${sv.talla_cm ? sv.talla_cm + " cm" : "—"}`;
    }

    if (antecedentes_relevantes) {
      userMessage += `\n\nANTECEDENTES RELEVANTES:\n${antecedentes_relevantes}`;
    }

    userMessage += `\n\nMOTIVO DE CONSULTA / SUBJETIVO:\n${motivo_consulta}`;

    if (exploracion_fisica) {
      userMessage += `\n\nEXPLORACIÓN FÍSICA:\n${exploracion_fisica}`;
    }

    userMessage += "\n\nGenera la nota completa en el formato indicado.";

    // ─── 5. Call Claude API ───
    const systemPrompt = SYSTEM_PROMPTS[tipo_nota] || SYSTEM_PROMPTS.soap;

    const claudeResponse = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": Deno.env.get("ANTHROPIC_API_KEY")!,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: "claude-sonnet-4-20250514",
        max_tokens: 2000,
        system: systemPrompt,
        messages: [
          { role: "user", content: userMessage }
        ],
      }),
    });

    if (!claudeResponse.ok) {
      const errorText = await claudeResponse.text();
      console.error("Claude API error:", errorText);
      return new Response(
        JSON.stringify({ error: "Error al generar nota con IA" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const claudeData = await claudeResponse.json();
    const notaGenerada = claudeData.content[0]?.text || "";

    const promptTokens     = claudeData.usage?.input_tokens  || 0;
    const completionTokens = claudeData.usage?.output_tokens || 0;
    const totalTokens      = promptTokens + completionTokens;
    const latencyMs        = Date.now() - startTime;

    // Approximate cost: claude-sonnet-4 pricing
    const costUSD = (promptTokens * 0.000003) + (completionTokens * 0.000015);

    // ─── 6. Log the AI usage ───
    await supabase.from("ai_note_log").insert({
      clinic_id:         profile.clinic_id,
      patient_id:        patient_id || null,
      doctor_id:         user.id,
      tipo_nota,
      prompt_tokens:     promptTokens,
      completion_tokens: completionTokens,
      total_tokens:      totalTokens,
      modelo:            "claude-sonnet-4-20250514",
      costo_usd:         costUSD,
      latencia_ms:       latencyMs,
    });

    // ─── 7. Optionally save note to patient record ───
    let savedNote = null;
    if (patient_id) {
      const { data: note, error: noteError } = await supabase
        .from("clinical_notes")
        .insert({
          clinic_id:        profile.clinic_id,
          patient_id:       patient_id,
          appointment_id:   appointment_id || null,
          doctor_id:        user.id,
          tipo_nota:        tipo_nota,
          nota_completa:    notaGenerada,
          generada_con_ia:  true,
          ia_modelo:        "claude-sonnet-4-20250514",
          estado:           "borrador",  // Doctor must review and sign
        })
        .select()
        .single();

      if (!noteError) savedNote = note;
    }

    // ─── 8. Return the generated note ───
    return new Response(
      JSON.stringify({
        success:    true,
        nota:       notaGenerada,
        note_id:    savedNote?.id || null,
        tokens:     totalTokens,
        latencia_ms: latencyMs,
        tipo_nota,
      }),
      {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" }
      }
    );

  } catch (error) {
    console.error("Edge function error:", error);
    return new Response(
      JSON.stringify({ error: "Error interno del servidor" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});

// ============================================================
// HOW TO CALL THIS FROM YOUR HTML/JS FRONTEND:
// ============================================================
//
// const { data: { session } } = await supabase.auth.getSession()
//
// const response = await fetch(
//   'https://YOUR-PROJECT.supabase.co/functions/v1/generate-clinical-note',
//   {
//     method: 'POST',
//     headers: {
//       'Authorization': `Bearer ${session.access_token}`,
//       'Content-Type': 'application/json',
//     },
//     body: JSON.stringify({
//       tipo_nota:        'soap',
//       motivo_consulta:  'Paciente acude a control de DM2...',
//       exploracion_fisica: 'Consciente, orientada...',
//       signos_vitales: {
//         ta_sistolica: 120,
//         ta_diastolica: 80,
//         frecuencia_cardiaca: 72,
//         temperatura: 36.5,
//         saturacion_o2: 98,
//         peso_kg: 62,
//         talla_cm: 165
//       },
//       patient_id: 'UUID-of-patient',         // Optional — saves to record
//       appointment_id: 'UUID-of-appointment', // Optional — links to appointment
//     })
//   }
// )
//
// const { nota, note_id } = await response.json()
// document.getElementById('ai-output').textContent = nota
// ============================================================
