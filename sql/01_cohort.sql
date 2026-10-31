-- 01_cohort.sql
-- MIMIC-IV v3.1 cohort: patients with >=1 chapter-5 diagnosis (ICD-10 F01-F99 or ICD-9 290-319),
-- any position. Instance = admission (hadm_id). FULL admission history of each cohort patient is kept.
-- Placeholders replaced by build_cohort.py: {project} {dataset}

CREATE OR REPLACE TABLE `{project}.{dataset}.cohort_admissions` AS
WITH dx AS (
  SELECT
    subject_id, hadm_id, seq_num,
    (icd_version = 10 AND STARTS_WITH(icd_code, 'F')) AS f10,
    COALESCE(icd_version = 9 AND SAFE_CAST(SUBSTR(icd_code, 1, 3) AS INT64) BETWEEN 290 AND 319, FALSE) AS f9,
    (icd_version = 10 AND STARTS_WITH(icd_code, 'F17'))
      OR (icd_version = 9 AND STARTS_WITH(icd_code, '3051')) AS tabaco
  FROM `physionet-data.mimiciv_3_1_hosp.diagnoses_icd`
),
psy_adm AS (
  SELECT hadm_id,
    LOGICAL_OR(f10 OR f9) AS any_psy,
    LOGICAL_OR((f10 OR f9) AND NOT tabaco) AS psy_sin_tabaco,
    LOGICAL_OR((f10 OR f9) AND seq_num = 1) AS psy_principal
  FROM dx GROUP BY hadm_id
),
cohort_pat AS (
  SELECT DISTINCT subject_id FROM dx WHERE f10 OR f9
),
cohort_pat_strict AS (
  SELECT DISTINCT subject_id FROM dx WHERE (f10 OR f9) AND NOT tabaco
),
ed_in AS (
  SELECT hadm_id, MIN(intime) AS ed_intime
  FROM `physionet-data.mimiciv_ed.edstays`
  WHERE hadm_id IS NOT NULL
  GROUP BY hadm_id
)
SELECT
  a.subject_id, a.hadm_id, a.admittime, a.dischtime, ei.ed_intime,
  a.admission_type,
  IF(a.admission_type IN ('EU OBSERVATION', 'DIRECT OBSERVATION', 'AMBULATORY OBSERVATION'),
     'observacion', 'hospitalizacion') AS tipo_estancia,
  ROW_NUMBER() OVER (PARTITION BY a.subject_id ORDER BY a.admittime, a.hadm_id) AS orden_admision,
  p.subject_id IS NOT NULL AS pat_strict,            -- patient has >=1 non-tobacco chapter-5 code
  COALESCE(pa.any_psy, FALSE) AS adm_psy,             -- admission has any chapter-5 code
  COALESCE(pa.psy_sin_tabaco, FALSE) AS adm_psy_sin_tabaco,
  COALESCE(pa.psy_principal, FALSE) AS adm_psy_principal   -- chapter-5 code as principal dx (seq_num = 1)
FROM `physionet-data.mimiciv_3_1_hosp.admissions` a
JOIN cohort_pat c USING (subject_id)
LEFT JOIN cohort_pat_strict p USING (subject_id)
LEFT JOIN psy_adm pa USING (hadm_id)
LEFT JOIN ed_in ei USING (hadm_id);
