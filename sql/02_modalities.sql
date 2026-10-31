-- 02_modalities.sql
-- Items per admission and modality (0 = modality absent). Requires 01_cohort.sql.
-- ECG has no hadm_id: matched by subject_id + time window.
--   n_ecg_ingreso  : [admittime, dischtime]
--   n_ecg_ampliado : [LEAST(admittime, ED intime), dischtime]
-- Placeholders: {project} {dataset}

CREATE OR REPLACE TABLE `{project}.{dataset}.modality_counts` AS
WITH c AS (
  SELECT hadm_id, subject_id, admittime, dischtime, ed_intime
  FROM `{project}.{dataset}.cohort_admissions`
),
labs AS (
  SELECT hadm_id, COUNT(*) AS n_labs
  FROM `physionet-data.mimiciv_3_1_hosp.labevents`
  WHERE hadm_id IN (SELECT hadm_id FROM c)
  GROUP BY hadm_id
),
dis AS (
  SELECT hadm_id, COUNT(*) AS n_discharge
  FROM `physionet-data.mimiciv_note.discharge` GROUP BY hadm_id
),
rad AS (
  SELECT hadm_id, COUNT(*) AS n_radiology
  FROM `physionet-data.mimiciv_note.radiology` GROUP BY hadm_id
),
edv AS (
  SELECT e.hadm_id, COUNT(*) AS n_ed_vitals
  FROM `physionet-data.mimiciv_ed.edstays` e
  JOIN `physionet-data.mimiciv_ed.vitalsign` v USING (stay_id)
  WHERE e.hadm_id IS NOT NULL
  GROUP BY e.hadm_id
),
uciv AS (
  SELECT i.hadm_id, COUNT(*) AS n_uci_vitals
  FROM `physionet-data.mimiciv_3_1_icu.icustays` i
  JOIN `physionet-data.mimiciv_3_1_derived.vitalsign` v USING (stay_id)
  GROUP BY i.hadm_id
),
ecg_ing AS (
  SELECT c.hadm_id, COUNT(*) AS n_ecg_ingreso
  FROM c JOIN `physionet-data.mimiciv_ecg.record_list` r
    ON r.subject_id = c.subject_id AND r.ecg_time BETWEEN c.admittime AND c.dischtime
  GROUP BY c.hadm_id
),
ecg_amp AS (
  SELECT c.hadm_id, COUNT(*) AS n_ecg_ampliado
  FROM c JOIN `physionet-data.mimiciv_ecg.record_list` r
    ON r.subject_id = c.subject_id
   AND r.ecg_time BETWEEN LEAST(c.admittime, COALESCE(c.ed_intime, c.admittime)) AND c.dischtime
  GROUP BY c.hadm_id
)
SELECT c.hadm_id, c.subject_id,
  COALESCE(n_labs, 0) AS n_labs,
  COALESCE(n_discharge, 0) AS n_discharge,
  COALESCE(n_radiology, 0) AS n_radiology,
  COALESCE(n_ed_vitals, 0) AS n_ed_vitals,
  COALESCE(n_uci_vitals, 0) AS n_uci_vitals,
  COALESCE(n_ecg_ingreso, 0) AS n_ecg_ingreso,
  COALESCE(n_ecg_ampliado, 0) AS n_ecg_ampliado
FROM c
LEFT JOIN labs USING (hadm_id) LEFT JOIN dis USING (hadm_id) LEFT JOIN rad USING (hadm_id)
LEFT JOIN edv USING (hadm_id) LEFT JOIN uciv USING (hadm_id)
LEFT JOIN ecg_ing USING (hadm_id) LEFT JOIN ecg_amp USING (hadm_id);
