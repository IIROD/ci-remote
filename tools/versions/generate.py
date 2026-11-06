#!/usr/bin/env python3
"""
Versions des apps Concept Assist (app client, app technicien) — calculées depuis l'historique git de main.

Même règle que le site et le serveur (décision du 06/11/2026, docs/plan-conformite-versions.md du site) :
  - une nouveauté (feat)        → 2e chiffre + 1, 3e remis à 0   (1.4.2 → 1.5.0)
  - une correction (fix)        → 3e chiffre + 1                 (1.5.0 → 1.5.1)
  - un changement majeur (!)    → 1er chiffre + 1                (1.5.1 → 2.0.0), seulement sur décision
  - documentation, CI, maintenance → la version ne bouge pas
Le premier changement d'une app vaut 1.0.0. « build-N » reste le numéro technique de compilation.

Seuls nos changements comptent : ceux qui suivent la base RustDesk (BASE, dernier commit amont repris). Un changement
= une pull request fusionnée (titre de la PR). L'app concernée se lit dans la portée du titre : feat(client): → app
client, feat(tech): ou feat(technicien): → app technicien, sans portée → les deux. Un changement qui ne touche que
.github/, docs/ ou des notes .md ne fait avancer aucune version. Les PR écrites avant cette règle sont classées une
fois pour toutes dans tools/versions/historique.tsv (sha court → type, résumé, apps).

Sortie : un fichier JSON (versions + journal), publié avec la release et épinglé avec elle dans Concept_Assist
(server/app-release.json, clé « versions ») : le journal du site montre ainsi la version réellement distribuée.
Usage : python3 tools/versions/generate.py [--build build-N] [--out versions.json]
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HIST = os.path.join(ROOT, "tools", "versions", "historique.tsv")
BASE = "e1ca0976"   # RustDesk 1.5.1 amont, juste avant notre premier commit
SYSTEMS = {"client": "App client", "tech": "App technicien"}

TYPES = {"feat": "Nouveau", "fix": "Corrigé", "security": "Sécurité", "major": "Majeur"}
CONV = re.compile(r"^(feat|feature|fix|docs|chore|style|test|refactor|perf|ci|build|revert)(\([^)]*\))?(!)?:\s*(.+)$", re.I)
VERSION_COMMIT = "chore(version):"


def git(*args):
    return subprocess.run(["git", "-C", ROOT, *args], check=True, capture_output=True, text=True).stdout


def load_history():
    """sha court (7) → (type, résumé, apps) pour les PR écrites avant la règle."""
    out = {}
    if os.path.exists(HIST):
        for line in open(HIST, encoding="utf-8"):
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            sha, typ, summary, apps = (line.split("\t") + ["", "", ""])[:4]
            out[sha[:7]] = (typ.strip(), summary.strip(), {a.strip() for a in apps.split(",") if a.strip() in SYSTEMS})
    return out


def commits():
    fmt = "%H%x1f%h%x1f%aI%x1f%s%x1f%b%x1e"
    raw = git("log", "--first-parent", "--reverse", f"--format={fmt}", f"{BASE}..HEAD")
    for rec in raw.split("\x1e"):
        rec = rec.strip("\n")
        if not rec:
            continue
        full, short, date, subject, body = (rec.split("\x1f") + [""] * 5)[:5]
        yield full, short[:7], date, subject.strip(), body.strip()


def files_of(sha):
    out = git("diff-tree", "--root", "--no-commit-id", "--name-only", "-r", "-m", "--first-parent", sha)
    return [f for f in out.splitlines() if f]


NOT_APP = re.compile(r"^(\.github/|docs/|tools/|[^/]+\.md$)")


def apps_of(short, subject, body, files, history):
    """Apps qu'un changement fait avancer : classement manuel, sinon portée du titre, sinon les deux."""
    if short in history and history[short][2]:
        return history[short][2]
    if not any(not NOT_APP.match(f) for f in files):
        return set()
    m = re.match(r"^Merge pull request #\d+ from ", subject)
    title = next((l for l in body.splitlines() if l.strip()), "") if m else subject
    scope = (CONV.match(title).group(2) or "").strip("()").lower() if CONV.match(title) else ""
    if scope == "client":
        return {"client"}
    if scope in ("tech", "technicien"):
        return {"tech"}
    return set(SYSTEMS)


def classify(short, subject, body, history):
    """Renvoie (type, titre, détail, ref PR) ; type None = ne compte pas."""
    ref = ""
    m = re.match(r"^Merge pull request #(\d+) from ", subject)
    if m:
        ref = "#" + m.group(1)
        lines = [l for l in body.splitlines() if l.strip()]
        subject, body = (lines[0] if lines else subject), "\n".join(lines[1:])
    elif subject.startswith("Merge "):
        return None, subject, "", ""
    m = re.search(r"\s\(#(\d+)\)$", subject)
    if m:
        ref = "#" + m.group(1)
        subject = subject[: m.start()]
    if subject.startswith(VERSION_COMMIT):
        return None, subject, "", ref
    if short in history:
        typ, summary, _ = history[short]
        return (typ if typ in TYPES else None), (summary or subject), body, ref
    c = CONV.match(subject)
    if c:
        kind, bang, title = c.group(1).lower(), c.group(3), c.group(4)
        if bang:
            kind = "major"
        elif kind == "feature":
            kind = "feat"
        elif kind not in ("feat", "fix", "build"):
            kind = None
        if kind in ("fix", "build") and re.search(r"s[ée]curit", c.group(2) or "", re.I):
            kind = "security"   # fix(securite): ou build(securite): (dépendances à failles connues)
        return (None if kind == "build" else kind), title[:1].upper() + title[1:], body, ref
    return "unclassified", subject, body, ref


NOISE = re.compile(r"^(co-authored-by:|claude-session:|-{5,}$|🤖 generated)", re.I)


def clean_detail(title, body):
    """Corps d'une PR fusionnée en « squash » : GitHub y empile les messages de tous les commits de la branche.
    On garde le bloc qui correspond à la PR (celui dont la première ligne reprend son titre, sinon le dernier),
    sans les lignes de signature."""
    if not body:
        return ""
    blocks = [b.strip() for b in re.split(r"(?m)^\* ", body) if b.strip()] if re.search(r"(?m)^\* ", body) else [body]
    key = re.sub(r"^[a-z]+(\([^)]*\))?!?:\s*", "", title, flags=re.I).strip().lower()[:40]
    pick = next((bl for bl in blocks if key and key in bl.splitlines()[0].lower()), blocks[-1])
    lines = [l for l in pick.splitlines() if not NOISE.match(l.strip())]
    if lines and key and key in lines[0].lower():
        lines = lines[1:]   # la première ligne répète le titre
    return "\n".join(lines).strip()


def bump(v, kind):
    a, b, c = v
    if kind == "major":
        return (a + 1, 0, 0)
    if kind == "feat":
        return (a, b + 1, 0)
    return (a, b, c + 1)   # fix, security


def build():
    history = load_history()
    current = {}
    entries, unclassified = [], []
    for full, short, date, subject, body in commits():
        kind, title, detail, ref = classify(short, subject, body, history)
        if kind == "unclassified":
            unclassified.append((short, subject))
            continue
        if not kind:
            continue
        for sysk in sorted(apps_of(short, subject, body, files_of(full), history)):
            v = bump(current[sysk], kind) if sysk in current else (1, 0, 0)
            current[sysk] = v
            entries.append({
                "system": sysk, "version": "%d.%d.%d" % v, "date": date[:10], "type": kind,
                "title": title.strip(), "detail": clean_detail(subject, detail)[:1200], "ref": ref, "sha": short,
            })
    if unclassified:
        sys.stderr.write("Commits à classer dans tools/versions/historique.tsv :\n")
        for short, subject in unclassified:
            sys.stderr.write(f"  {short}\t{subject}\n")
        sys.exit(2)
    entries.reverse()
    latest = {}
    for e in entries:
        latest.setdefault(e["system"], {"version": e["version"], "date": e["date"], "name": SYSTEMS[e["system"]]})
    return {"systems": latest, "entries": entries}


def main():
    args = sys.argv[1:]
    opt = lambda name: args[args.index(name) + 1] if name in args and args.index(name) + 1 < len(args) else ""
    data = build()
    if re.fullmatch(r"build-\d+", opt("--build")):
        for s in data["systems"].values():
            s["build"] = opt("--build")
    js = json.dumps(data, ensure_ascii=False, indent=1) + "\n"
    if opt("--out"):
        open(opt("--out"), "w", encoding="utf-8").write(js)
    sys.stderr.write(" · ".join(f"{v['name']} v{v['version']} ({v['date']})" for v in data["systems"].values()) + "\n")
    if not opt("--out"):
        sys.stdout.write(js)


if __name__ == "__main__":
    main()
