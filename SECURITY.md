# Security Policy

## Scope

agent-airlock est un **sandbox de sécurité** : son but est précisément de contenir un agent
non fiable. Toute vulnérabilité permettant à l'agent de **sortir du sandbox** est considérée
critique.

Exemples de vulnérabilités dans le périmètre :

- Network isolation bypass (direct internet access without going through the proxy)
- Egress allowlist bypass (access to an unauthorized domain)
- Host secret leakage into the Claude container
- Privilege escalation in the container (root access, unexpected host mounts)
- Command injection in the launcher or entrypoint

## Reporting a Vulnerability

**Ne pas ouvrir d'issue publique** pour signaler une vulnérabilité de sécurité.

Utilise le canal **[Private vulnerability reporting](https://github.com/Akeuuh/agent-airlock/security/advisories/new)**
de GitHub (onglet Security → Report a vulnerability).

Tu recevras une réponse dans les **7 jours**. Si la vulnérabilité est confirmée, un correctif
sera publié avant toute divulgation publique (coordinated disclosure).

## Out of Scope

- Attacks requiring physical access or root on the host machine
- Vulnerabilities in third-party dependencies (Podman, Squid, Claude Code) — report
  directly to the relevant maintainers
- General hardening improvements (open a normal issue or PR)
