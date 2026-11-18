# Keeping GitHub and Cloudflare in sync

Use `Brian-Uong/btc-prediction-market-research` on GitHub as the source of truth for this project. Check the latest `main` before making changes. For each change to the model, Worker, D1 schema or views, runner, reviewer behavior, or operational configuration, commit the corresponding source, migration or documentation to GitHub in the same task. Verify the commit on `main` and check the affected live behavior before reporting completion. If either side fails, report which revision is active and what still needs to sync.

Keep credentials, private account identifiers, journal rows and raw vendor data out of public commits. Regular market captures and settlements are data updates handled by D1.
