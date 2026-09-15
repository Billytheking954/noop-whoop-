# ScoreBench

ScoreBench is NOOP's offline, blind scalar benchmark against an independently exported WHOOP reference.
It evaluates Recovery, Sleep Performance, Day Strain, resting heart rate, HRV (RMSSD), and respiratory
rate without exposing reference values to the prediction-generation step.

## Contract

1. Freeze participant-level `development`/`holdout` assignments and record the split-plan SHA-256.
2. Generate `predictions.json` using NOOP only. Prediction rows contain a sample id and values; they do not
   contain WHOOP values, participant ids, or split assignments.
3. Keep `references.json` separate. Reference rows contain sample id, participant id, frozen partition, and
   WHOOP values.
4. Join only with `evaluate`. Never tune from the holdout report.
5. Use `gate` before a production change. It refuses promotion if any selected held-out metric loses
   coverage, emits an out-of-range value, increases MAE/RMSE, or if no selected metric strictly improves MAE.

WHOOP is a consumer reference, not medical ground truth. Sleep-stage tuning belongs in SleepPSG against
independent epoch labels; ScoreBench's sleep field is only the scalar Sleep Performance comparison.

## Commands

```sh
python3 Tools/ScoreBench/scorebench.py evaluate \
  --predictions predictions.json --references references.json --output report.json

python3 Tools/ScoreBench/scorebench.py gate \
  --incumbent incumbent-report.json --candidate candidate-report.json \
  --metric recovery_score_pct --output promotion.json

python3 -m unittest Tools/ScoreBench/test_scorebench.py
```

The process is local and standard-library only. Reports include reference count, valid paired count,
missing/invalid predictions, coverage, MAE, RMSE, signed bias, Pearson correlation, and the safeguard range.
