import pandas as pd

SIGNALS = ["loss", "grad_norm", "stable_rank", "weight_update_magnitude"]
WINDOW = 5
FEATURE_COLS = [f"{c}_{s}" for c in SIGNALS for s in ("roll_mean", "roll_std", "trend")]


def add_features(df):
    df = df.sort_values("iter").reset_index(drop=True).copy()
    for c in SIGNALS:
        df[f"{c}_roll_mean"] = df[c].rolling(WINDOW, min_periods=1).mean()
        df[f"{c}_roll_std"] = df[c].rolling(WINDOW, min_periods=1).std().fillna(0)
        df[f"{c}_trend"] = df[c].diff().fillna(0)
    return df
