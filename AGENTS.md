# Shared Development Rules

- Develop incrementally, one assigned module at a time.
- Both members develop on M2. Member 1 owns frontend review and authorizes frontend development on M2. Member 2 owns backend review and continues backend development on M2.
- Use the respective frontend and backend branches from M2 for independent changes. An explicitly approved cross-stack task may use one agreed integration branch to keep its contract and implementation together.
- For T8.1, both members approve the workspace architecture and shared contract direction, with frontend and backend changes reviewed together from the backend branch.
- Preserve both owners' review before committing or pushing approved cross-stack changes. Integrate reviewed work through pull requests into main.
- Confirm the current branch before editing.
- Obtain approval before changing shared configuration, dependencies, architecture, or API contracts.
- Never push directly to `main` or force-push.
- Test each completed module.
- Report modified files, testing results, and integration requirements.
- Never expose credentials or API keys.
- Do not automatically start the next module.
- Do not generate the entire project at once.
