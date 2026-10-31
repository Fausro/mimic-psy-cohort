# mimic-psy-cohort

Definición reproducible de la cohorte **MIMIC-IV, capítulo 5 (ICD-10 F01-F99 / ICD-9 290-319)** para el consorcio HumanAIze.
El repositorio **no contiene datos**: solo código. Cada persona con acceso credencial a PhysioNet reconstruye la cohorte en su propio BigQuery y verifica que coincide con la de referencia.

## Requisitos

- Cuenta PhysioNet con acceso (DUA firmado) a los módulos de BigQuery: `mimiciv_3_1_hosp`, `mimiciv_3_1_icu`, `mimiciv_3_1_derived`, `mimiciv_ed`, `mimiciv_note`, `mimiciv_ecg`.
- Un proyecto de Google Cloud propio y `gcloud auth application-default login`.
- `pip install -r requirements.txt`

## Uso

```bash
python build_cohort.py --project TU_PROYECTO            # construye las tablas y verifica
python build_cohort.py --project TU_PROYECTO --no-build # solo verifica tablas existentes
python build_cohort.py --project TU_PROYECTO --skip-modalities  # solo cohorte (más rápido)
```

Crea en `TU_PROYECTO.mimic_cohorte` (región US):

- `cohort_admissions`: una fila por admission (`hadm_id`) del historial completo de cada paciente de la cohorte.
- `modality_counts`: nº de elementos por admission y modalidad (labs, discharge, radiology, ED vitals, UCI vitals, ECG).

## Definición (instancias)

1. **Paciente de la cohorte**: tiene al menos un diagnóstico en `hosp.diagnoses_icd` con `icd_version=10` y código que empieza por `F`, o `icd_version=9` y los tres primeros caracteres entre 290 y 319 (cualquier `seq_num`).
2. **Instancia**: admission (`hadm_id`). Se incluye el historial **completo** de esos pacientes, con y sin código F.
3. Columnas de `cohort_admissions` para filtrar:

| Columna | Significado |
|---|---|
| `adm_psy` | la admission tiene algún código del capítulo 5 |
| `adm_psy_sin_tabaco` | ídem excluyendo F17 (ICD-10) y 3051x (ICD-9) |
| `adm_psy_principal` | el código del capítulo 5 es el diagnóstico principal (`seq_num=1`) |
| `tipo_estancia` | `observacion` si `admission_type` ∈ {EU OBSERVATION, DIRECT OBSERVATION, AMBULATORY OBSERVATION}; `hospitalizacion` en el resto |
| `orden_admision` | posición cronológica de la admission en el paciente (desempate por `hadm_id`) |
| `pat_strict` | el paciente tiene al menos un código del capítulo 5 distinto de tabaco |

Subconjuntos de uso habitual:

| Nombre | Filtro |
|---|---|
| C1 (amplia) | `adm_psy` |
| C2 | `adm_psy AND tipo_estancia='hospitalizacion'` |
| C3 | `adm_psy_principal AND tipo_estancia='hospitalizacion'` |
| C4 | `adm_psy_principal AND tipo_estancia='observacion'` |
| Incidente | primera admission con `adm_psy` y `orden_admision > 1` |

## Verificación sin compartir IDs

`expected_counts.json` contiene los conteos de referencia y el SHA-256 de la lista ordenada de `hadm_id` (completa y solo `adm_psy`). Si tu build coincide, tienes exactamente la misma cohorte. Si no, el script lista las diferencias (típicamente, otra versión de las tablas de PhysioNet).

> Los hashes se rellenan una vez con `python build_cohort.py --project TU_PROYECTO --update-expected` en el build de referencia.

## Datos y DUA

- El repositorio no incluye datos ni listas de identificadores; `.gitignore` excluye `output/` y los CSV.
- `--export-ids DIR` genera un CSV local con IDs y flags para uso propio. No lo subas a GitHub ni a ninguna API externa.
- Antes de compartir listas de IDs con terceros, consulta la política de PhysioNet sobre datos derivados.

## Limitaciones

- ECG se enlaza por ventana temporal (no hay `hadm_id`); con ventanas ampliadas, un mismo ECG puede contarse en dos admissions solapadas.
- Los labs ambulatorios (`hadm_id` nulo) no entran.
- "Primera admission" significa primera dentro de MIMIC (un hospital, 2008-2022), no primera en la vida del paciente.
