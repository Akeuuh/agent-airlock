# Security Policy

## Scope

agent-airlock est un **sandbox de sécurité** : son but est précisément de contenir un agent
non fiable. Toute vulnérabilité permettant à l'agent de **sortir du sandbox** est considérée
critique.

Exemples de vulnérabilités dans le périmètre :

- Contournement de l'isolation réseau (accès internet direct sans passer par le proxy)
- Bypass de l'allowlist egress (accès à un domaine non autorisé)
- Fuite de secrets hôte vers le conteneur Claude
- Escalade de privilèges dans le conteneur (accès root, montage hôte non prévu)
- Injection de commandes dans le launcher ou l'entrypoint

## Reporting a Vulnerability

**Ne pas ouvrir d'issue publique** pour signaler une vulnérabilité de sécurité.

Utilise le canal **[Private vulnerability reporting](https://github.com/Akeuuh/agent-airlock/security/advisories/new)**
de GitHub (onglet Security → Report a vulnerability).

Tu recevras une réponse dans les **7 jours**. Si la vulnérabilité est confirmée, un correctif
sera publié avant toute divulgation publique (coordinated disclosure).

## Out of Scope

- Attaques nécessitant un accès physique ou root sur la machine hôte
- Vulnérabilités dans les dépendances tierces (Podman, Squid, Claude Code) — reporter
  directement aux mainteneurs concernés
- Améliorations générales de hardening (ouvrir une issue normale ou une PR)
