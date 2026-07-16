## Description

<!-- Explique le problème résolu ou la fonctionnalité ajoutée. Le "pourquoi", pas le "quoi". -->

## Type de changement

- [ ] `feat` — nouvelle capacité
- [ ] `fix` — correction de bug
- [ ] `harden` — durcissement sécurité / réduction de surface
- [ ] `docs` — documentation
- [ ] `chore` — tooling, build, ménage

## Checklist PR

- [ ] `agent-doctor` **vert** (isolation réseau, allowlist, sidecars)
- [ ] Aucun secret commité (tokens, `.env` réels, clés)
- [ ] Modif réseau (allowlist / port publié) **justifiée** dans le commit et aussi restrictive que possible (sous-domaine exact, pas de wildcard)
- [ ] Un nouveau MCP a un `ALLOWED_TOOLS` restrictif (aucun tool destructeur exposé)
- [ ] Doc à jour si le comportement change
- [ ] Pas d'élévation de privilèges dans les conteneurs (`--privileged` absent, pas de montage hôte superflu, l'agent reste user `claude`)
