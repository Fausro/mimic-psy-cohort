#!/usr/bin/env python3
"""Build the MIMIC-IV chapter-5 cohort (ICD-10 F01-F99 / ICD-9 290-319) in YOUR BigQuery dataset.

Examples
--------
python build_cohort.py --project my-gcp-project                      # build + verify
python build_cohort.py --project my-gcp-project --no-build           # verify existing tables only
python build_cohort.py --project my-gcp-project --export-ids output/ # local CSV (NEVER commit it)
python build_cohort.py --project my-gcp-project --update-expected    # reference build only
"""
import argparse
import csv
import hashlib
import json
import sys
from pathlib import Path

from google.cloud import bigquery

ROOT = Path(__file__).resolve().parent
EXPECTED = ROOT / "expected_counts.json"
SCRIPTS = ["sql/01_cohort.sql", "sql/02_modalities.sql"]


def render(rel_path, project, dataset):
    sql = (ROOT / rel_path).read_text()
    return sql.replace("{project}", project).replace("{dataset}", dataset)


def run_script(client, rel_path, project, dataset):
    print(f"[run] {rel_path}")
    client.query(render(rel_path, project, dataset)).result()


def one_row(client, query):
    row = next(iter(client.query(query).result()))
    return {k: int(v) for k, v in row.items()}


def id_hash(client, table, where="TRUE"):
    """SHA-256 of the sorted hadm_id list: lets others verify the cohort without sharing IDs."""
    h = hashlib.sha256()
    q = f"SELECT hadm_id FROM `{table}` WHERE {where} ORDER BY hadm_id"
    for r in client.query(q).result():
        h.update(f"{r[0]}\n".encode())
    return h.hexdigest()


def collect(client, project, dataset):
    t = f"{project}.{dataset}.cohort_admissions"
    out = {"cohort": one_row(client, f"""
        SELECT COUNT(DISTINCT subject_id) AS pacientes,
               COUNT(DISTINCT IF(pat_strict, subject_id, NULL)) AS pacientes_sin_solo_tabaco,
               COUNT(*) AS admissions_historial,
               COUNTIF(adm_psy) AS admissions_con_F,
               COUNTIF(adm_psy_sin_tabaco) AS admissions_con_F_sin_tabaco,
               COUNTIF(adm_psy_principal) AS admissions_F_principal
        FROM `{t}`""")}
    m = f"{project}.{dataset}.modality_counts"
    try:
        out["modalities"] = one_row(client, f"""
            SELECT COUNTIF(n_labs > 0) AS labs, COUNTIF(n_discharge > 0) AS discharge,
                   COUNTIF(n_radiology > 0) AS radiology, COUNTIF(n_ed_vitals > 0) AS ed_vitals,
                   COUNTIF(n_uci_vitals > 0) AS uci_vitals,
                   COUNTIF(n_ecg_ampliado > 0) AS ecg_ampliado,
                   COUNTIF(n_ecg_ingreso > 0) AS ecg_ingreso
            FROM `{m}`""")
    except Exception:
        print("[info] modality_counts not found, skipping modality checks")
    out["hash_hadm_id_all"] = id_hash(client, t)
    out["hash_hadm_id_adm_psy"] = id_hash(client, t, "adm_psy")
    return out


def compare(got, expected):
    bad = []
    for section in ("cohort", "modalities"):
        for k, v in expected.get(section, {}).items():
            if section in got and got[section].get(k) != v:
                bad.append(f"{section}.{k}: got {got[section].get(k)}, expected {v}")
    for k in ("hash_hadm_id_all", "hash_hadm_id_adm_psy"):
        exp = expected.get(k)
        if exp is None:
            print(f"[warn] no stored {k} (run --update-expected on the reference build)")
        elif got[k] != exp:
            bad.append(f"{k}: got {got[k][:12]}..., expected {exp[:12]}...")
    return bad


def export_ids(client, project, dataset, outdir):
    outdir = Path(outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    q = f"""SELECT subject_id, hadm_id, orden_admision, tipo_estancia,
                   adm_psy, adm_psy_sin_tabaco, adm_psy_principal, pat_strict
            FROM `{project}.{dataset}.cohort_admissions`
            ORDER BY subject_id, orden_admision"""
    rows = client.query(q).result()
    path = outdir / "cohort_admissions.csv"
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow([c.name for c in rows.schema])
        for r in rows:
            w.writerow(list(r.values()))
    print(f"[export] {path}  (contains IDs: do NOT commit or publish)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--project", required=True, help="your GCP project (billing + destination)")
    ap.add_argument("--dataset", default="mimic_cohorte", help="destination dataset (created in US)")
    ap.add_argument("--no-build", action="store_true", help="skip SQL, only verify/export")
    ap.add_argument("--skip-modalities", action="store_true", help="skip 02_modalities.sql (heavy)")
    ap.add_argument("--update-expected", action="store_true", help="overwrite expected_counts.json")
    ap.add_argument("--export-ids", metavar="DIR", help="write a local CSV with IDs and flags")
    a = ap.parse_args()

    client = bigquery.Client(project=a.project)
    ds = bigquery.Dataset(f"{a.project}.{a.dataset}")
    ds.location = "US"   # MIMIC lives in US; cross-region queries are not allowed
    client.create_dataset(ds, exists_ok=True)

    if not a.no_build:
        for s in SCRIPTS[: 1 if a.skip_modalities else 2]:
            run_script(client, s, a.project, a.dataset)

    got = collect(client, a.project, a.dataset)
    print(json.dumps(got, indent=2))

    if a.export_ids:
        export_ids(client, a.project, a.dataset, a.export_ids)

    if a.update_expected:
        EXPECTED.write_text(json.dumps(got, indent=2) + "\n")
        print(f"[ok] wrote {EXPECTED.name}")
        return

    bad = compare(got, json.loads(EXPECTED.read_text()))
    if bad:
        print("[MISMATCH] cohort differs from the reference:")
        for b in bad:
            print("  -", b)
        sys.exit(1)
    print("[OK] cohort matches the reference build")


if __name__ == "__main__":
    main()
