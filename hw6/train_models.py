"""
HW6 Part 3: reads the requests from the 3NF tables in Cloud SQL, trains two
models and writes their test-set output to the HW5 bucket.

  Model 1  client IP -> country
           DecisionTreeClassifier on the IP as one 32-bit integer. Countries
           own contiguous IP blocks, so the tree learns the block boundaries
           (one split per boundary) and a leaf per block.
           The split is by IP (GroupShuffleSplit): no test IP is ever seen in
           training, so the score measures generalisation, not memorisation.

  Model 2  age, gender, hour of day, country -> income
           HistGradientBoostingClassifier (age, gender, country categorical).
           Also reports a majority-class baseline, the best possible accuracy
           given age (the only informative field) and a seed sweep.

Output (gs://$BUCKET/$OUT_PREFIX/):
  country_model_test_predictions.csv   one row per test request
  income_model_test_predictions.csv    one row per test request
  model_summary.txt                    accuracies + explanation

Env: SEED (528), TEST_SIZE (0.2), BUCKET (cs528-amernor), OUT_PREFIX (hw6),
     SWEEP_SEEDS (10), plus the DB settings in db.py.
Usage: python train_models.py
"""
import io
import os
import time

import numpy as np
import pandas as pd
import sqlalchemy
from google.cloud import storage
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.metrics import accuracy_score
from sklearn.model_selection import GroupShuffleSplit, train_test_split
from sklearn.tree import DecisionTreeClassifier

import db

SEED = int(os.environ.get("SEED", "528"))
TEST_SIZE = float(os.environ.get("TEST_SIZE", "0.2"))
BUCKET = os.environ.get("BUCKET", "cs528-amernor")
OUT_PREFIX = os.environ.get("OUT_PREFIX", "hw6").strip("/")
SWEEP_SEEDS = int(os.environ.get("SWEEP_SEEDS", "10"))

# requests from the load-test client (scanner rows without headers have no IP)
QUERY = """
SELECT r.id, r.client_ip, c.name AS country, r.gender, r.age, r.income,
       r.time_of_day
FROM requests_3nf r
JOIN client_ips ip ON ip.client_ip = r.client_ip
JOIN countries  c  ON c.country_id = ip.country_id
WHERE r.gender IS NOT NULL AND r.age IS NOT NULL AND r.income IS NOT NULL
  AND r.time_of_day IS NOT NULL
ORDER BY r.id
"""

AGE_ORDER = ["0-16", "17-25", "26-35", "36-45", "46-55", "56-65", "66-75", "76+"]
INCOME_ORDER = ["0-10k", "10k-20k", "20k-40k", "40k-60k", "60k-100k",
                "100k-150k", "150k-250k", "250k+"]

summary = []


def say(line=""):
    print(line, flush=True)
    summary.append(line)


def load_data():
    engine = db.make_engine()
    with engine.connect() as conn:
        df = pd.read_sql(sqlalchemy.text(QUERY), conn)
    engine.dispose()
    return df


def ip_to_int(ips):
    """'a.b.c.d' -> a*2^24 + b*2^16 + c*2^8 + d, so IP order = number order."""
    octets = ips.str.split(".", expand=True).astype(np.int64)
    return octets[0] * 2**24 + octets[1] * 2**16 + octets[2] * 2**8 + octets[3]


def upload(bucket, name, data, content_type):
    blob = bucket.blob(f"{OUT_PREFIX}/{name}")
    blob.upload_from_string(data, content_type=content_type)
    say(f"  wrote gs://{BUCKET}/{OUT_PREFIX}/{name}")


def csv_bytes(frame):
    buf = io.StringIO()
    frame.to_csv(buf, index=False)
    return buf.getvalue()


# --------------------------------------------------------------- model 1
def country_model(df):
    X = ip_to_int(df.client_ip).to_frame("ip_int")
    y = df.country
    split = GroupShuffleSplit(n_splits=1, test_size=TEST_SIZE, random_state=SEED)
    train_idx, test_idx = next(split.split(X, y, groups=df.client_ip))

    model = DecisionTreeClassifier(random_state=SEED)
    t0 = time.time()
    model.fit(X.iloc[train_idx], y.iloc[train_idx])
    fit_s = time.time() - t0
    pred = model.predict(X.iloc[test_idx])
    acc = accuracy_score(y.iloc[test_idx], pred)
    train_acc = model.score(X.iloc[train_idx], y.iloc[train_idx])
    test = df.iloc[test_idx]
    overlap = len(set(test.client_ip) & set(df.client_ip.iloc[train_idx]))

    say("=" * 70)
    say("MODEL 1: client IP -> country")
    say("=" * 70)
    say("Model:    DecisionTreeClassifier on the IP as a 32-bit integer")
    say(f"Split:    by IP (GroupShuffleSplit, test_size={TEST_SIZE}, seed={SEED});"
        f" test IPs also in training: {overlap}")
    say(f"Rows:     train {len(train_idx)}, test {len(test_idx)}"
        f" ({test.client_ip.nunique()} distinct test IPs, {y.nunique()} countries)")
    say(f"Tree:     depth {model.get_depth()}, {model.get_n_leaves()} leaves"
        f" (= IP blocks learned), fit in {fit_s:.2f}s")
    say(f"Train accuracy: {train_acc:.4%}")
    say(f"TEST ACCURACY:  {acc:.4%}   ({int((pred == y.iloc[test_idx]).sum())}"
        f"/{len(test_idx)} correct; target >= 99%)")
    wrong = test.assign(predicted=pred)[pred != y.iloc[test_idx].to_numpy()]
    if len(wrong):
        say("Misclassified test rows (first 10):")
        for r in wrong.head(10).itertuples():
            say(f"  {r.client_ip:<16} actual {r.country:<24} predicted {r.predicted}")
    say()

    out = pd.DataFrame({
        "request_id": test.id.to_numpy(),
        "client_ip": test.client_ip.to_numpy(),
        "actual_country": y.iloc[test_idx].to_numpy(),
        "predicted_country": pred,
    })
    out["correct"] = out.actual_country == out.predicted_country
    return out


# --------------------------------------------------------------- model 2
def income_features(df):
    return pd.DataFrame({
        "age": pd.Categorical(df.age, categories=AGE_ORDER),
        "gender": pd.Categorical(df.gender),
        "country": pd.Categorical(df.country),
        "hour": pd.to_datetime(df.time_of_day).dt.hour,
    }, index=df.index)


def fit_income(X, y, seed):
    Xtr, Xte, ytr, yte = train_test_split(X, y, test_size=TEST_SIZE,
                                          random_state=seed, stratify=y)
    model = HistGradientBoostingClassifier(categorical_features="from_dtype",
                                           random_state=seed)
    model.fit(Xtr, ytr)
    return model, Xtr, Xte, ytr, yte


def income_model(df):
    X, y = income_features(df), df.income
    model, Xtr, Xte, ytr, yte = fit_income(X, y, SEED)
    pred = model.predict(Xte)
    acc = accuracy_score(yte, pred)

    # baselines on the same split
    majority = ytr.value_counts().idxmax()
    base_acc = (yte == majority).mean()
    by_age = ytr.groupby(Xtr.age, observed=True).agg(lambda s: s.value_counts().idxmax())
    age_acc = (Xte.age.map(by_age).astype(str) == yte).mean()
    # best accuracy any model can expect when only age carries information:
    # always guess the most common income of each age group
    share = pd.crosstab(df.age, df.income, normalize="index")
    ceiling = (share.max(axis=1) * df.age.value_counts(normalize=True)).sum()

    say("=" * 70)
    say("MODEL 2: (age, gender, hour of day, country) -> income")
    say("=" * 70)
    say("Model:    HistGradientBoostingClassifier (age/gender/country categorical)")
    say(f"Split:    random, stratified by income (test_size={TEST_SIZE}, seed={SEED})")
    say(f"Rows:     train {len(Xtr)}, test {len(Xte)}, {y.nunique()} income classes")
    say(f"Train accuracy: {model.score(Xtr, ytr):.4%}")
    say(f"TEST ACCURACY:  {acc:.4%}   ({int((pred == yte).sum())}/{len(yte)} correct;"
        f" target 35%)")
    say()
    say("Comparison on the same test set:")
    say(f"  majority class ('{majority}') : {base_acc:.4%}")
    say(f"  most common income per age     : {age_acc:.4%}")
    say(f"  ceiling if only age matters    : {ceiling:.4%}")
    say()

    sweep = []
    for s in range(SWEEP_SEEDS):
        m, _, Xte_s, _, yte_s = fit_income(X, y, s)
        sweep.append(m.score(Xte_s, yte_s))
    sweep = np.array(sweep)
    say(f"Seed sweep (seeds 0-{SWEEP_SEEDS - 1}, new split + model each time):")
    say("  " + "  ".join(f"{a:.2%}" for a in sweep))
    say(f"  mean {sweep.mean():.2%}, min {sweep.min():.2%}, max {sweep.max():.2%};"
        f" seeds reaching 35%: {(sweep >= 0.35).sum()}/{len(sweep)}")
    say()
    say("Income share within each age group (rows sum to 100%):")
    share = share.reindex(index=AGE_ORDER, columns=INCOME_ORDER)
    say("  " + share.map(lambda v: f"{v:.0%}" if v else "-").to_string().replace("\n", "\n  "))
    say()
    say("Why 35% is out of reach: each age group spreads evenly over exactly 3")
    say("income groups, and gender, hour and country carry no further signal")
    say("(all-field model ~= age-only lookup). The best any model can expect on")
    say(f"unseen rows is ~1/3 ({ceiling:.2%}); scores above that on one split are")
    say("noise, which is the seed sensitivity the assignment warns about.")
    say()

    test = df.loc[Xte.index]
    out = pd.DataFrame({
        "request_id": test.id.to_numpy(),
        "age": test.age.to_numpy(),
        "gender": test.gender.to_numpy(),
        "hour": Xte.hour.to_numpy(),
        "country": test.country.to_numpy(),
        "actual_income": yte.to_numpy(),
        "predicted_income": pred,
    })
    out["correct"] = out.actual_income == out.predicted_income
    return out


def main():
    started = time.time()
    say(f"HW6 models  (run started {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())},"
        f" host {os.uname().nodename})")
    df = load_data()
    say(f"Loaded {len(df)} requests from {db.INSTANCE_CONNECTION_NAME}/{db.DB_NAME}"
        " (requests_3nf JOIN client_ips JOIN countries)")
    say()

    country_out = country_model(df)
    income_out = income_model(df)

    say(f"Finished in {time.time() - started:.1f}s. Output files:")
    bucket = storage.Client(project=db.PROJECT_ID).bucket(BUCKET)
    upload(bucket, "country_model_test_predictions.csv", csv_bytes(country_out), "text/csv")
    upload(bucket, "income_model_test_predictions.csv", csv_bytes(income_out), "text/csv")
    upload(bucket, "model_summary.txt", "\n".join(summary) + "\n", "text/plain")


if __name__ == "__main__":
    main()
