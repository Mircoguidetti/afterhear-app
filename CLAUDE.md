# Start here (every new session)

This repository holds only the apps. The owner's rules, the state of the project and the plan
live in the private repository `Mircoguidetti/afterhear`, branch `dev`: read `docs/HANDOFF.md` and
`docs/PIANO.md` there before doing anything. Talk to the owner in Italian.

- Nothing that spends credits (Gemini through the server, paid services, anything billed) is launched without the owner's explicit go, with its estimated cost said first (owner, 06/10). Tests that call the server run only by hand. No paid speech services: the voices stay on the device.
- Never put secrets in this repository: it is public. Keys and tokens go only in GitHub secrets.
- App test builds: push to `dev` (publishes the release `mac-test`); `main` once, when ready.
- No `pull_request` triggers in the workflows: nothing from a fork may run with this repository's secrets.
