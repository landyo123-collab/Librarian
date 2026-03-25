# Trigger Resources

- `triggers-base.csv`: editable source list of generic trigger terms and scores.
- `triggers-generated.json`: runtime lexicon loaded by Librarian when present.

Regenerate after editing CSV:

```bash
python3 Scripts/build_triggers.py
```
