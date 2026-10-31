# ci-remote — app d'assistance à distance de Concept Informatique

Ce dépôt est une version **modifiée de [RustDesk](https://github.com/rustdesk/rustdesk)**
(base : version officielle **1.5.1**), publiée sous la même licence, **AGPL-3.0** (voir `LICENCE`).
« ci-remote » est un nom provisoire.

## Pourquoi ce dépôt

Concept Informatique (Belgique) utilise RustDesk avec son propre serveur pour l'assistance à
distance de ses clients. Les modifications prévues :

- rattachement automatique du PC au compte client du site ;
- ouverture de la session en un clic depuis la console du magasin ;
- accord du client à chaque session, élévation des droits dès l'acceptation ;
- information du serveur sur l'activité du technicien (compteur de temps) ;
- nom et logo propres (« RustDesk » est une marque de ses auteurs et n'est pas utilisé pour
  l'app distribuée).

## Compilation

`.github/workflows/concept-windows.yml` compile l'exe portable Windows x64 à chaque pull request
et à chaque push sur `main` (artefact téléchargeable depuis l'onglet **Actions**, non signé).

Les workflows automatiques d'origine (toutes plateformes, publication de versions, tâches
nocturnes) ont été retirés ; les workflows réutilisables restent.

## Suivre RustDesk

Les nouvelles versions officielles sont fusionnées depuis le tag correspondant de RustDesk :

```bash
git remote add upstream https://github.com/rustdesk/rustdesk.git
git fetch upstream tag <version>
git merge <version>
```
