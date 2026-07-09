# Template de git hooks NEUTRE monté dans le conteneur Claude.
#
# core.hooksPath pointe ici (voir containers/claude/entrypoint.sh) pour que les
# hooks créés/modifiés par l'agent NE SOIENT PAS persistés sur l'hôte : cela ferme
# une voie d'évasion du sandbox (un hook malveillant s'exécuterait au prochain
# `git commit` de l'utilisateur sur sa machine).
#
# Laisser ce dossier vide (aucun hook actif).
